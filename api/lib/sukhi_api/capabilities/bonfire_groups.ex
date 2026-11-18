# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.BonfireGroups do
  @moduledoc """
  Join / leave a remote group, on the paths Bonfire's draft
  "Mastodon-Compatible Groups & Topics API" names
  (`POST /api/v1-bonfire/groups/:id/join`, `…/leave`), so a client written
  for that API reaches sukhi the same way. The `:id` is the group's
  account id, as for `/api/v1/accounts/:id/follow`.

  Both answer with the `Relationship`, which carries `group:
  {member, role}` once a membership exists. A join waits for the group's
  `Accept`: until then `requested` is true and `group.member` false.
  Leaving a group you're not in answers the Relationship too, as
  `unfollow` does.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.MastodonRelationship

  @impl true
  def routes do
    [
      {:post, "/api/v1-bonfire/groups/:id/join", &join/1, scope: "write:follows"},
      {:post, "/api/v1-bonfire/groups/:id/leave", &leave/1, scope: "write:follows"}
    ]
  end

  @doc "Join a group, or ask to join it."
  def join(req), do: membership(req, :join_group)

  @doc "Leave a group, or cancel a join it hasn't answered."
  def leave(req), do: membership(req, :leave_group)

  defp membership(req, fun) do
    %{current_account: viewer} = req[:assigns]
    id = req[:path_params]["id"]

    with %{} = v <- viewer,
         {:ok, group_id} <- parse_int(id),
         :ok <- change(fun, v, group_id),
         {:ok, [rel | _]} <- GatewayRpc.run(SukhiFedi.Social, :list_relationships, [v, [group_id]]) do
      ok(200, MastodonRelationship.render(rel))
    else
      nil -> ok(403, %{error: "this endpoint requires a user-bound token"})
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
      {:error, :not_found} -> ok(404, %{error: "group_not_found"})
      {:error, :not_remote} -> ok(422, %{error: "not a remote group"})
      {:error, reason} -> ok(422, %{error: inspect(reason)})
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
      _ -> ok(500, %{error: "internal_error"})
    end
  end

  defp change(:join_group, viewer, group_id), do: run(:join_group, viewer, group_id)

  defp change(:leave_group, viewer, group_id) do
    case run(:leave_group, viewer, group_id) do
      # Leaving a group you're not in is already done, as `unfollow` is.
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  defp run(fun, viewer, group_id) do
    case GatewayRpc.run(SukhiFedi.Social, fun, [viewer, group_id]) do
      {:ok, _membership} -> :ok
      other -> other
    end
  end

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_int}
    end
  end

  defp parse_int(n) when is_integer(n), do: {:ok, n}
  defp parse_int(_), do: {:error, :bad_int}

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
