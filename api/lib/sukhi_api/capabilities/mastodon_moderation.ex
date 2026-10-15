# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonModeration do
  @moduledoc """
  User-facing moderation surface.

      POST   /api/v1/accounts/:id/block       write:blocks
      POST   /api/v1/accounts/:id/unblock     write:blocks
      POST   /api/v1/accounts/:id/mute        write:mutes
      POST   /api/v1/accounts/:id/unmute      write:mutes
      GET    /api/v1/blocks                   read:blocks
      GET    /api/v1/mutes                    read:mutes
      POST   /api/v1/reports                  write:reports
      GET    /api/v1/domain_blocks            follow
      POST   /api/v1/domain_blocks            follow
      DELETE /api/v1/domain_blocks            follow

  Backed by `SukhiFedi.Addons.Moderation`. Block/unblock returns the
  refreshed Relationship for parity with Mastodon clients that pipe
  the response straight back into their account model.
  """

  use SukhiApi.Capability, addon: :moderation

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.{Id, MastodonAccount, MastodonRelationship}

  @impl true
  def routes do
    [
      {:post, "/api/v1/accounts/:id/block", &block/1, scope: "write:blocks"},
      {:post, "/api/v1/accounts/:id/unblock", &unblock/1, scope: "write:blocks"},
      {:post, "/api/v1/accounts/:id/mute", &mute/1, scope: "write:mutes"},
      {:post, "/api/v1/accounts/:id/unmute", &unmute/1, scope: "write:mutes"},
      {:get, "/api/v1/blocks", &list_blocks/1, scope: "read:blocks"},
      {:get, "/api/v1/mutes", &list_mutes/1, scope: "read:mutes"},
      {:post, "/api/v1/reports", &create_report/1, scope: "write:reports"},
      {:get, "/api/v1/domain_blocks", &list_domain_blocks/1, scope: "follow"},
      {:post, "/api/v1/domain_blocks", &block_domain/1, scope: "follow"},
      {:delete, "/api/v1/domain_blocks", &unblock_domain/1, scope: "follow"}
    ]
  end

  def block(req), do: rel_action(req, :block)
  def unblock(req), do: rel_action(req, :unblock)
  def mute(req), do: rel_action(req, :mute)
  def unmute(req), do: rel_action(req, :unmute)

  defp rel_action(req, op) do
    with_viewer(req, fn v ->
      id = parse_id(req[:path_params]["id"])

      if is_nil(id) do
        ok(404, %{error: "not_found"})
      else
        # The inner result may be {:error, changeset} (e.g. already
        # blocked) — the refetched Relationship below reports what
        # actually took effect, so only transport failures are errors.
        case call_op(op, v.id, id) do
          {:unavailable, _} = e ->
            rpc_error(e)

          _answered ->
            rel =
              case GatewayRpc.run(SukhiFedi.Social, :list_relationships, [v, [id]]) do
                {:ok, [r]} -> r
                _ -> %{id: id}
              end

            ok(200, MastodonRelationship.render(rel))
        end
      end
    end)
  end

  defp call_op(:block, viewer_id, target_id),
    do: GatewayRpc.run(SukhiFedi.Addons.Moderation, :block, [viewer_id, target_id])

  defp call_op(:unblock, viewer_id, target_id),
    do: GatewayRpc.run(SukhiFedi.Addons.Moderation, :unblock, [viewer_id, target_id])

  defp call_op(:mute, viewer_id, target_id),
    do: GatewayRpc.run(SukhiFedi.Addons.Moderation, :mute, [viewer_id, target_id])

  defp call_op(:unmute, viewer_id, target_id),
    do: GatewayRpc.run(SukhiFedi.Addons.Moderation, :unmute, [viewer_id, target_id])

  def list_blocks(req), do: list_relationship(req, :list_blocks)
  def list_mutes(req), do: list_relationship(req, :list_mutes)

  defp list_relationship(req, fun) do
    with_viewer(req, fn v ->
      case GatewayRpc.run(SukhiFedi.Addons.Moderation, fun, [v.id]) do
        {:ok, accounts} when is_list(accounts) ->
          ok(200, Enum.map(accounts, &MastodonAccount.render(&1, %{})))

        e ->
          # An empty 200 here would tell the client "you block nobody"
          # while the gateway is merely unreachable.
          rpc_error(e)
      end
    end)
  end

  def create_report(req) do
    with_viewer(req, fn v ->
      body = decode_body(req)
      target_id = parse_id(body["account_id"])
      note_id = parse_id(body["status_ids"] && List.wrap(body["status_ids"]) |> List.first())
      comment = body["comment"] || ""

      if is_nil(target_id) do
        ok(422, %{error: "missing_account_id"})
      else
        attrs = %{
          account_id: v.id,
          target_id: target_id,
          note_id: note_id,
          comment: comment
        }

        case GatewayRpc.run(SukhiFedi.Addons.Moderation, :create_report, [attrs]) do
          {:ok, report} ->
            ok(200, %{
              id: Id.encode(report.id),
              action_taken: false,
              comment: report.comment || "",
              created_at: format_dt(Map.get(report, :inserted_at))
            })

          {:error, _} ->
            ok(422, %{error: "validation_failed"})

          e ->
            rpc_error(e)
        end
      end
    end)
  end

  def list_domain_blocks(req) do
    with_viewer(req, fn _v ->
      case GatewayRpc.run(SukhiFedi.Addons.Moderation, :list_instance_blocks, [
             %{offset: 0, limit: 200}
           ]) do
        {:ok, {rows, _total}} ->
          ok(200, Enum.map(rows, fn r -> r.domain end))

        e ->
          rpc_error(e)
      end
    end)
  end

  def block_domain(req) do
    with_viewer(req, fn v ->
      body = decode_body(req)

      case body["domain"] do
        d when is_binary(d) and d != "" ->
          case GatewayRpc.run(SukhiFedi.Addons.Moderation, :block_instance, [
                 d,
                 "silence",
                 "",
                 v.id
               ]) do
            {:ok, _block} -> ok(200, %{})
            {:error, _} -> ok(422, %{error: "block_failed"})
            e -> rpc_error(e)
          end

        _ ->
          ok(422, %{error: "missing_domain"})
      end
    end)
  end

  def unblock_domain(req) do
    with_viewer(req, fn v ->
      body = decode_body(req)

      case body["domain"] do
        d when is_binary(d) and d != "" ->
          case GatewayRpc.run(SukhiFedi.Addons.Moderation, :unblock_instance, [d, v.id]) do
            {:ok, _} -> ok(200, %{})
            # Deleting a block that isn't there is idempotent.
            {:error, :not_found} -> ok(200, %{})
            {:error, _} -> ok(422, %{error: "unblock_failed"})
            e -> rpc_error(e)
          end

        _ ->
          ok(422, %{error: "missing_domain"})
      end
    end)
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp with_viewer(req, fun) do
    case req[:assigns][:current_account] do
      nil -> ok(403, %{error: "this endpoint requires a user-bound token"})
      %{} = v -> fun.(v)
    end
  end

  defp decode_body(req) do
    case req[:body] do
      nil -> %{}
      "" -> %{}
      body when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> URI.decode_query(body)
        end

      body when is_map(body) ->
        body
    end
  end

  defp parse_id(nil), do: nil
  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_dt(_), do: nil

  defp rpc_error({:unavailable, why}), do: ok(503, GatewayRpc.unavailable_body(why))

  defp rpc_error(_), do: ok(500, %{error: "internal_error"})

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
