# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Streaming.NatsListener do
  use GenServer
  alias SukhiFedi.Addons.Streaming.Registry

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @subject "stream.new_post"

  @impl true
  def init(_) do
    # Subscribing in init/1 meant this listener could take the whole
    # application down with it. Gnat.ConnectionSupervisor connects
    # asynchronously, so `:gnat` is not always there yet by the time the
    # addon children start — and when it isn't, Gnat.sub does not return
    # an error, it exits. On 2026-08-24 a deploy hit exactly that: the
    # first boot died on `failed_to_start_child: NatsListener` and only
    # the supervisor above us retrying saved it.
    #
    # So: try in a continue, retry on failure, and let the app finish
    # booting either way. Same shape as SukhiFedi.WtRelayTelemetry.
    {:ok, %{subscribed: false, gnat: nil}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state), do: {:noreply, try_subscribe(state)}

  defp try_subscribe(%{subscribed: true} = state), do: state

  # 購読は `:gnat` の接続プロセスにぶら下がっている。NATS が落ちて
  # ConnectionSupervisor が新しい接続を立て直すと、購読も一緒に消えるのに、
  # こちらには何も届かない ── 2026-08-27 に NATS を再起動したとき、
  # `fedify.>` の micro service は自分で張り直したのに、ここだけ黙って
  # 止まったままになった。だから接続プロセスを見張って、落ちたら張り直す。
  #
  # `whereis` を `Gnat.sub` より先に取るのは、二重購読を作らないため ──
  # あいだで接続が入れ替わったら、monitor した古い pid がすぐ `:DOWN` で
  # 返ってきて、そこから張り直しに入る。
  defp try_subscribe(state) do
    with pid when is_pid(pid) <- Process.whereis(:gnat),
         {:ok, _sub} <- Gnat.sub(:gnat, self(), @subject) do
      %{state | subscribed: true, gnat: Process.monitor(pid)}
    else
      _ -> schedule_resubscribe(state)
    end
  rescue
    _ -> schedule_resubscribe(state)
  catch
    # :gnat がプロセスごと居ないとき、Gnat.sub は例外でなく exit(noproc)
    # ─ rescue では受からない。
    :exit, _ -> schedule_resubscribe(state)
  end

  defp schedule_resubscribe(state) do
    Process.send_after(self(), :resubscribe, 2_000)
    state
  end

  @impl true
  def handle_info(:resubscribe, state), do: {:noreply, try_subscribe(state)}

  # 接続ごと購読が消えた。新しい接続が立つのを待って張り直す。
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{gnat: ref} = state) do
    {:noreply, schedule_resubscribe(%{state | subscribed: false, gnat: nil})}
  end

  # もう見ていない monitor（張り直したあとに届いた前の分）は捨てる。
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:msg, %{topic: @subject, body: body}}, state) do
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
  catch
    # ここも sub と同じ ─ :gnat が居ないと exit(noproc) で来るので、rescue
    # だけでは「落とさない」と書いてあるのに落ちていた。
    :exit, _ -> :ok
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
