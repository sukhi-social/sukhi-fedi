# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Streaming do
  @moduledoc """
  Gateway entry point for pushing events to connected streaming clients.

  The streaming sockets and their broadcaster Registry live on the
  gateway (see `SukhiFedi.Addons.Streaming`), but Mastodon entities are
  rendered on the api plugin node (it owns the views). So the api renders
  a payload and calls in here via `GatewayRpc` — rendering stays on the
  api, fan-out stays where the sockets are.

  Best-effort by design: streaming is an optional addon, so when its
  Registry isn't running these calls are a no-op rather than an error. A
  dropped stream frame must never fail the write that produced it.
  """

  alias SukhiFedi.Addons.Streaming.Registry
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Notification

  @doc """
  Push a freshly-created DM to each local participant's `direct` stream.
  `targets` is `[%{account_id, conversation}]` where `conversation` is an
  already-rendered Mastodon Conversation map (viewer-relative).
  """
  @spec publish_direct([%{account_id: integer(), conversation: map()}]) :: :ok
  def publish_direct(targets) when is_list(targets) do
    if registry_running?() do
      Enum.each(targets, fn %{account_id: account_id, conversation: conversation} ->
        Registry.broadcast(:direct, %{event: "conversation", payload: conversation}, account_id)
      end)
    end

    :ok
  end

  @doc """
  Push a notification to the recipient's `user` stream as a Mastodon
  `notification` event. Rendering lives on the api node (it owns the
  views), so we render over `:rpc` and fan out here where the sockets
  are — mirroring `publish_direct/1`, but the producer is server-side
  (a notification has no api request in flight), so the gateway drives
  the render.

  Fully best-effort and off the caller's path: it only fires when a
  client is actually streaming (otherwise the render RPC is wasted), runs
  in a Task, and swallows every failure. A dropped notification frame
  must never disturb the write that created the notification.
  """
  @spec publish_notification(integer(), Notification.t()) :: :ok
  def publish_notification(account_id, %Notification{} = notif) when is_integer(account_id) do
    if registry_running?() and Registry.has_subscribers?(:home, account_id) do
      Task.start(fn -> render_and_push(account_id, notif) end)
    end

    :ok
  end

  @doc """
  Publish a freshly-created post to the `stream.new_post` NATS subject. The
  gateway's own `NatsListener` consumes it and fans out to the `:local` /
  `:home` streaming feeds (SSE/WS) *and* to the per-feed NATS subjects that the
  WebTransport edge (karutte) subscribes to.

  `object` is the already-rendered Mastodon Status (the api owns the views, so
  it renders and hands it here); `actor_id` is the author's AP actor URI
  (`https://<domain>/users/<username>`). Best-effort — a dropped stream frame
  must never fail the write that produced the post.
  """
  @spec publish_new_post(map(), String.t()) :: :ok
  def publish_new_post(object, actor_id) when is_binary(actor_id) do
    Gnat.pub(:gnat, "stream.new_post", JSON.encode!(%{object: object, actor_id: actor_id}))
    :ok
  rescue
    _ -> :ok
  end

  defp render_and_push(account_id, notif) do
    notif = Repo.preload(notif, [:from_account, note: [:account, :media, :tags]])

    case render_notification(notif) do
      {:ok, json} ->
        Registry.broadcast(:home, %{event: "notification", payload: json}, account_id)

      :error ->
        :ok
    end
  end

  # The Mastodon Notification view is pure and built to survive the RPC
  # hop (associations arrive as plain maps). Render it on the api node.
  defp render_notification(notif) do
    case plugin_node() do
      nil ->
        :error

      node ->
        case :rpc.call(node, SukhiApi.Views.MastodonNotification, :render, [notif], 5_000) do
          %{} = json -> {:ok, json}
          _ -> :error
        end
    end
  end

  defp plugin_node, do: Application.get_env(:sukhi_fedi, :plugin_nodes, []) |> List.first()

  defp registry_running?, do: is_pid(Process.whereis(Registry))
end
