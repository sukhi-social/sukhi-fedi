# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.Join do
  @moduledoc """
  Asking to join (docs/JOIN.md). Transport only: validation is the gateway
  changeset's, the per-address mail limit is `JoinApplications`', and the
  per-peer limit is the gateway route's.

    * `GET  /api/v1/join/info`      — who looks at applications, and which day
    * `POST /api/v1/join`           — write one; the receipt mail goes out
    * `POST /api/v1/join/received`  — `{claim}`: "I got the mail"; the edit link goes out
    * `POST /api/v1/join/email`     — `{claim, email}`: fix the address, before any "yes"
    * `POST /api/v1/join/lookup`    — `{key}`: the words behind an edit link
    * `POST /api/v1/join/edit`      — `{key, ...}`: rewrite them

  All open: nobody has an account yet. The two secrets (`claim` for the
  browser that applied, `key` for the mailed link) travel in bodies, never
  in a URL, so they stay out of access logs.
  """

  use SukhiApi.Capability

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.Join

  @fields ~w(email call_name found hope lang)
  @words ~w(call_name found hope)
  # A mail goes out inside these calls; SMTP can take longer than the default.
  @mail_timeout 20_000

  @impl true
  def routes do
    [
      {:get, "/api/v1/join/info", &info/1},
      {:post, "/api/v1/join", &create/1},
      {:post, "/api/v1/join/received", &received/1},
      {:post, "/api/v1/join/email", &email/1},
      {:post, "/api/v1/join/lookup", &lookup/1},
      {:post, "/api/v1/join/edit", &edit/1}
    ]
  end

  def info(_req) do
    case GatewayRpc.run(SukhiFedi.JoinApplications, :info, []) do
      {:ok, info} -> ok(200, Join.render_info(info))
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
    end
  end

  def create(req) do
    attrs = req |> decode_body() |> Map.take(@fields)

    case GatewayRpc.run(SukhiFedi.JoinApplications, :submit, [attrs], @mail_timeout) do
      {:ok, %{application: app, claim: claim, check: check}} ->
        ok(202, Join.render_applied(app, claim, check))
      {:error, reason} -> failure(reason)
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
    end
  end

  def received(req) do
    claim = req |> decode_body() |> secret("claim")

    case GatewayRpc.run(SukhiFedi.JoinApplications, :received, [claim], @mail_timeout) do
      {:ok, app} -> ok(200, %{receipt: app.receipt})
      {:error, reason} -> failure(reason)
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
    end
  end

  def email(req) do
    body = decode_body(req)

    case GatewayRpc.run(
           SukhiFedi.JoinApplications,
           :change_email,
           [secret(body, "claim"), to_string(body["email"] || "")],
           @mail_timeout
         ) do
      {:ok, app} -> ok(200, %{receipt: app.receipt})
      {:error, reason} -> failure(reason)
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
    end
  end

  def lookup(req) do
    key = req |> decode_body() |> secret("key")

    case GatewayRpc.run(SukhiFedi.JoinApplications, :fetch_by_key, [key]) do
      {:ok, app} -> ok(200, Join.render_application(app))
      {:error, reason} -> failure(reason)
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
    end
  end

  def edit(req) do
    body = decode_body(req)

    case GatewayRpc.run(SukhiFedi.JoinApplications, :edit, [
           secret(body, "key"),
           Map.take(body, @words)
         ]) do
      {:ok, app} -> ok(200, Join.render_application(app))
      {:error, reason} -> failure(reason)
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Every domain "no" in one place, with the status the page keys on.
  defp failure(:not_found), do: ok(404, %{error: "join_not_found"})
  defp failure(:confirmed), do: ok(409, %{error: "join_confirmed"})
  defp failure(:rate_limited), do: ok(429, %{error: "rate_limited"})
  defp failure(:send_failed), do: ok(502, %{error: "send_failed"})

  defp failure(%{} = cs),
    do: ok(422, %{error: "validation_failed", details: cs_errors(cs)})

  defp cs_errors(%{errors: errors}), do: Map.new(errors, fn {k, {msg, _}} -> {k, msg} end)
  defp cs_errors(_), do: %{}

  defp secret(body, key) do
    case body[key] do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  defp decode_body(req) do
    case JSON.decode(req[:body] || "") do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
