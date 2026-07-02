# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Streaming.NatsListener do
  use GenServer
  alias SukhiFedi.Addons.Streaming.Registry

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, _sub} = Gnat.sub(:gnat, self(), "stream.new_post")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:msg, %{topic: "stream.new_post", body: body}}, state) do
    case JSON.decode(body) do
      {:ok, %{"object" => object, "actor_id" => actor_id}} ->
        broadcast_to_feeds(object, actor_id)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  defp broadcast_to_feeds(object, actor_id) do
    event = %{event: "update", payload: object}

    if local_actor?(actor_id) do
      Registry.broadcast(:local, event)
      # WebTransport エッジ(karutte)は別ノードで in-process Registry を見られないので、
      # 共有 feed も NATS subject に出す。karutte が stream.local を sub して全接続へ。
      nats_pub("stream.local", object)
    end

    broadcast_to_followers(actor_id, event, object)
  end

  defp broadcast_to_followers(actor_id, event, object) do
    case extract_account_id(actor_id) do
      {:ok, account_id} ->
        # exclusive circle にこの著者を入れているフォロワーは home に出さない
        # （Timelines.home/2 のフィルタと揃える）。circle 越しの投稿が home stream に
        # 漏れないように。
        get_follower_account_ids(account_id)
        |> Enum.reject(fn follower_id ->
          account_id in SukhiFedi.Lists.excluded_account_ids(follower_id)
        end)
        |> Enum.each(fn follower_id ->
          Registry.broadcast(:home, event, follower_id)
          # karutte 用: 本人の user feed（チケットの sub = account_id）へ。
          nats_pub("stream.user.#{follower_id}", object)
        end)

      _ ->
        :ok
    end
  end

  # karutte が受ける per-feed subject へ。best-effort（NATS が無くても投稿は落とさない）。
  defp nats_pub(subject, object) do
    Gnat.pub(:gnat, subject, JSON.encode!(object))
  rescue
    _ -> :ok
  end

  defp local_actor?(actor_id) do
    domain = SukhiFedi.Config.domain!()
    String.starts_with?(actor_id, "https://#{domain}")
  end

  defp extract_account_id(actor_id) do
    domain = SukhiFedi.Config.domain!()

    case Regex.run(~r|https://#{Regex.escape(domain)}/users/(.+)|, actor_id) do
      [_, username] ->
        case SukhiFedi.Repo.get_by(SukhiFedi.Schema.Account, username: username) do
          nil -> :error
          account -> {:ok, account.id}
        end

      _ ->
        :error
    end
  end

  defp get_follower_account_ids(account_id) do
    import Ecto.Query
    domain = SukhiFedi.Config.domain!()

    SukhiFedi.Repo.all(
      from(f in SukhiFedi.Schema.Follow,
        where: f.followee_id == ^account_id and f.state == "accepted",
        where: fragment("? LIKE ?", f.follower_uri, ^"https://#{domain}%"),
        select: f.follower_uri
      )
    )
    |> Enum.map(fn uri ->
      case extract_account_id(uri) do
        {:ok, id} -> id
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
