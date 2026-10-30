# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonAccountMigration do
  @moduledoc """
  Account migration surface (Mastodon-standard Move + `alsoKnownAs`),
  scoped to the honest subset.

    * `GET  /api/v1/accounts/migration`        — current aliases + moved-to
    * `POST /api/v1/accounts/migration/aliases` — set the full alias set
    * `POST /api/v1/accounts/migration/move`    — move to a target identity

  All require a user-bound `write:accounts` token (the read echoes back
  the caller's own state, so it's bound to the same scope). Business
  rules — consent, validation, the transactional Move — live on the
  gateway (`SukhiFedi.AccountMigration`); this is transport only.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc

  @impl true
  def routes do
    [
      {:get, "/api/v1/accounts/migration", &show/1, scope: "read:accounts"},
      {:post, "/api/v1/accounts/migration/aliases", &set_aliases/1, scope: "write:accounts"},
      {:post, "/api/v1/accounts/migration/move", &move/1, scope: "write:accounts"}
    ]
  end

  # ── read ───────────────────────────────────────────────────────────────────

  # The account in `req` comes from the token cache (up to 60 s old), so a
  # just-saved alias set would read back stale. Ask the gateway for the row.
  def show(req) do
    with_account(req, fn %{id: id} ->
      case GatewayRpc.run(SukhiFedi.Accounts, :get_account, [id]) do
        {:ok, account} ->
          ok(200, %{
            aliases: Map.get(account, :aliases) || [],
            moved_to: Map.get(account, :moved_to_uri)
          })

        {:error, :not_found} ->
          ok(404, %{error: "account_not_found"})

        other ->
          gateway_error(other)
      end
    end)
  end

  # ── aliases ─────────────────────────────────────────────────────────────────

  def set_aliases(req) do
    with_account(req, fn %{id: id} ->
      aliases = decode_body(req) |> Map.get("aliases", []) |> List.wrap()

      case GatewayRpc.run(SukhiFedi.AccountMigration, :set_aliases, [id, aliases]) do
        {:ok, account} ->
          ok(200, %{aliases: account.aliases || []})

        {:error, :too_many} ->
          ok(422, %{error: "too_many_aliases"})

        {:error, {:invalid_alias, _entry}} ->
          ok(422, %{error: "invalid_alias"})

        {:error, :not_found} ->
          ok(404, %{error: "account_not_found"})

        other ->
          gateway_error(other)
      end
    end)
  end

  # ── move ────────────────────────────────────────────────────────────────────

  def move(req) do
    with_account(req, fn %{id: id} ->
      target = decode_body(req) |> Map.get("target", "") |> to_string()

      case GatewayRpc.run(SukhiFedi.AccountMigration, :move, [id, target]) do
        {:ok, account} ->
          ok(200, %{moved_to: account.moved_to_uri})

        {:error, :consent_missing} ->
          ok(422, %{error: "target_must_alias_back"})

        {:error, :invalid_target} ->
          ok(422, %{error: "invalid_target"})

        {:error, :already_moved} ->
          ok(422, %{error: "already_moved"})

        {:error, :not_found} ->
          ok(404, %{error: "account_not_found"})

        other ->
          gateway_error(other)
      end
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Every route here is the caller acting on their own account; a
  # client_credentials token has no user identity and is refused once,
  # here, so each handler can assume a real account.
  defp with_account(req, fun) do
    case req[:assigns][:current_account] do
      nil -> ok(403, %{error: "this endpoint requires a user-bound token"})
      %{} = account -> fun.(account)
    end
  end

  defp decode_body(req) do
    headers = req[:headers] || []
    ct = content_type(headers)

    cond do
      String.contains?(ct, "application/json") ->
        case JSON.decode(req[:body] || "") do
          {:ok, %{} = m} -> m
          _ -> %{}
        end

      String.contains?(ct, "application/x-www-form-urlencoded") ->
        URI.decode_query(req[:body] || "")

      true ->
        %{}
    end
  end

  defp content_type(headers) do
    Enum.find_value(headers, "", fn {k, v} ->
      if String.downcase(to_string(k)) == "content-type", do: to_string(v), else: nil
    end)
  end

  defp gateway_error({:unavailable, why}), do: ok(503, GatewayRpc.unavailable_body(why))

  defp gateway_error(_), do: ok(500, %{error: "internal_error"})

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
