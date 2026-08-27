# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.WtRelayTelemetry do
  @moduledoc """
  Holds the latest L4 telemetry snapshot the WebTransport edge relay (wt-relay,
  on the x64 box) publishes to the `wt_relay.telemetry` NATS subject every few
  seconds, so the `/admin/system` page can show it alongside sukhi's own
  host metrics — one place to watch both the app and the edge.

  wt-relay lives on another box and sees the flood at L4 (before the crypto
  handshake), so its raw packet rate catches spoofed / pre-handshake floods
  that QUIC's own stats can't. We keep the last two snapshots and derive
  per-second rates from their delta; `snapshot/0` returns the current values
  plus those rates, or `nil` when nothing has been received yet.

  Best-effort: if the relay is down (or NATS is unreachable) the numbers just
  go stale — the admin page shows how long ago the last sample arrived.
  """
  use GenServer

  @subject "wt_relay.telemetry"

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Latest snapshot with per-second rates, or nil if the relay hasn't reported."
  def snapshot do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, :snapshot, 1_000)
    end
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(_) do
    # :gnat がまだ繋がっていなくても落ちないよう、subscribe は continue で試み、
    # 失敗したら後で再試行する（NATS が起動途中／一時的に落ちていても回復する）。
    {:ok, %{prev: nil, curr: nil, received_at: nil, subscribed: false, gnat: nil},
     {:continue, :subscribe}}
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
    # ─ rescue では受からない。ここで受けないと 2 秒ごとの再試行が
    # crash 連発になり、supervisor の max_restarts で app ごと落ちる。
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

  def handle_info({:msg, %{body: body}}, state) do
    case decode(body) do
      {:ok, snap} ->
        {:noreply, %{prev: state.curr, curr: snap, received_at: System.system_time(:second)}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, build(state), state}

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{"routes" => routes} = m} when is_list(routes) -> {:ok, m}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Current raw values + per-second rates from the delta to the previous sample.
  # `ts` is snapshot-level, so dt is shared by every route in the pair.
  defp build(%{curr: nil}), do: nil

  defp build(%{curr: curr, prev: prev, received_at: at}) do
    dt =
      with %{"ts" => c} <- curr, %{"ts" => p} <- prev || %{}, true <- is_number(c) and is_number(p) do
        c - p
      else
        _ -> 0
      end

    %{
      received_at: at,
      conntrack: curr["conntrack"],
      routes: Enum.map(curr["routes"], &with_rate(&1, prev, dt))
    }
  end

  defp with_rate(route, prev, dt) do
    prev_route =
      prev &&
        Enum.find(prev["routes"] || [], fn p ->
          p["table"] == route["table"] and p["dport"] == route["dport"]
        end)

    {pps, bps} =
      if prev_route && dt > 0 do
        {delta(route["pkts"], prev_route["pkts"]) / dt, delta(route["bytes"], prev_route["bytes"]) / dt}
      else
        {nil, nil}
      end

    Map.merge(route, %{"pps" => pps, "bps" => bps})
  end

  # counters only climb; a drop means the chain was flushed (reconcile) — treat as 0.
  defp delta(cur, prev) when is_integer(cur) and is_integer(prev) and cur >= prev, do: cur - prev
  defp delta(_, _), do: 0
end
