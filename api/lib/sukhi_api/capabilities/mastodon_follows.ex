# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonFollows do
  @moduledoc """
  Mastodon follow / unfollow. Both routes return a single
  `Relationship` JSON shaped by `MastodonRelationship.render/1`.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.MastodonRelationship

  @impl true
  def routes do
    [
      {:post, "/api/v1/accounts/:id/follow", &follow/1, scope: "write:follows"},
      {:post, "/api/v1/accounts/:id/unfollow", &unfollow/1, scope: "write:follows"}
    ]
  end

  def follow(req) do
    %{current_account: viewer} = req[:assigns]
    id = req[:path_params]["id"]

    with %{} = v <- viewer,
         {:ok, target_id} <- parse_int(id),
         {:ok, _follow} <- GatewayRpc.run(SukhiFedi.Social, :request_follow, [v, target_id]),
         {:ok, [rel | _]} <- relationships(v, [target_id]) do
      ok(200, MastodonRelationship.render(rel))
    else
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      {:error, :bad_int} ->
        ok(400, %{error: "invalid_id"})

      {:error, :not_found} ->
        ok(404, %{error: "account_not_found"})

      {:error, :self_follow} ->
        ok(422, %{error: "you can't follow yourself"})

      {:error, reason} ->
        ok(422, %{error: inspect(reason)})

      {:unavailable, why} ->
        ok(503, GatewayRpc.unavailable_body(why))

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end

  def unfollow(req) do
    %{current_account: viewer} = req[:assigns]
    id = req[:path_params]["id"]

    with %{} = v <- viewer,
         {:ok, target_id} <- parse_int(id) do
      case GatewayRpc.run(SukhiFedi.Social, :unfollow, [v, target_id]) do
        {:ok, _follow} ->
          respond_with_relationship(v, target_id)

        {:error, :not_found} ->
          # Unfollowing when there's no follow is idempotent in Mastodon
          # — return a Relationship with following=false rather than 404.
          respond_with_relationship(v, target_id)

        {:unavailable, why} ->
          ok(503, GatewayRpc.unavailable_body(why))

        _ ->
          ok(500, %{error: "internal_error"})
      end
    else
      nil -> ok(403, %{error: "this endpoint requires a user-bound token"})
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
    end
  end

  defp relationships(viewer, ids) do
    GatewayRpc.run(SukhiFedi.Social, :list_relationships, [viewer, ids])
  end

  # The refetch can fail on transport like any RPC — answer 503, not a
  # MatchError-turned-500.
  defp respond_with_relationship(v, target_id) do
    case relationships(v, [target_id]) do
      {:ok, [rel | _]} -> ok(200, MastodonRelationship.render(rel))
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
      _ -> ok(500, %{error: "internal_error"})
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
