# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullFederation.Puller do
  @moduledoc """
  Decides *when* to pull, and from whom. The state is in the database
  (`pull_pending`, `pull_cursors`, `pull_hosts`), so a restart loses nothing;
  this process only holds who is being pulled from right now.

  Every `tick_ms` it starts a pull for each host that has something pending
  and whose `next_pull_at` has come, up to `max_concurrent` at a time. That
  bound is the receiver's half of backpressure: when we are busy, hosts wait
  in the table, not in a queue of connections. A host that declines is left
  alone for as long as it asked; one that fails backs off exponentially with
  jitter (`backoff_ms/1`); one that has more for us is asked again at once.

  Config (`config :sukhi_fedi, :pull_federation`): `:tick_ms` (nil turns the
  process off — the test env), `:max_concurrent`.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias SukhiFedi.PullFederation.{Notify, Pull}
  alias SukhiFedi.Repo
  alias SukhiShared.Capability

  @default_tick 1_000
  @default_concurrent 4
  @max_backoff_ms 3_600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Look for work now rather than at the next tick."
  def wake, do: GenServer.cast(__MODULE__, :wake)

  @doc "Seconds-scale exponential backoff with full jitter, capped."
  @spec backoff_ms(pos_integer()) :: pos_integer()
  def backoff_ms(failures) do
    base = min(1_000 * Integer.pow(2, min(failures, 12)), @max_backoff_ms)
    div(base, 2) + :rand.uniform(max(div(base, 2), 1))
  end

  @impl true
  def init(_opts) do
    cfg = Application.get_env(:sukhi_fedi, :pull_federation, [])

    case Keyword.get(cfg, :tick_ms, @default_tick) do
      nil ->
        :ignore

      tick ->
        send(self(), :tick)

        {:ok,
         %{tick: tick, max: Keyword.get(cfg, :max_concurrent, @default_concurrent), running: %{}}}
    end
  end

  @impl true
  def handle_cast(:wake, state), do: {:noreply, start_due(state)}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick)
    {:noreply, start_due(state)}
  end

  def handle_info({ref, outcome}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {host, running} = Map.pop(state.running, ref)
    if host, do: record(host, outcome)
    {:noreply, %{state | running: running}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {host, running} = Map.pop(state.running, ref)
    if host, do: record(host, {:error, {:crashed, reason}})
    {:noreply, %{state | running: running}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_due(%{running: running, max: max} = state) do
    free = max - map_size(running)

    if free <= 0 or not Capability.advertised?() do
      state
    else
      busy = MapSet.new(Map.values(running))

      due_hosts(free + MapSet.size(busy))
      |> Enum.reject(&MapSet.member?(busy, &1))
      |> Enum.take(free)
      |> Enum.reduce(state, fn host, st ->
        task =
          Task.Supervisor.async_nolink(SukhiFedi.PullFederation.TaskSup, fn -> Pull.run(host) end)

        %{st | running: Map.put(st.running, task.ref, host)}
      end)
    end
  rescue
    e ->
      Logger.warning("pull scheduler: #{Exception.message(e)}")
      state
  end

  defp due_hosts(limit) do
    now = NaiveDateTime.utc_now()

    waiting =
      from(p in "pull_pending",
        group_by: p.host,
        select: {p.host, min(p.received_at)}
      )
      |> Repo.all()

    next =
      from(h in "pull_hosts",
        where: h.host in ^Enum.map(waiting, &elem(&1, 0)),
        select: {h.host, type(h.next_pull_at, :naive_datetime_usec)}
      )
      |> Repo.all()
      |> Map.new()

    waiting
    |> Enum.filter(fn {host, _} ->
      case Map.get(next, host) do
        nil -> true
        at -> NaiveDateTime.compare(at, now) != :gt
      end
    end)
    |> Enum.sort_by(&elem(&1, 1), NaiveDateTime)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 0))
  end

  # ── scheduling the next pull of a host from how this one went ───────────

  @doc false
  @spec record(String.t(), Pull.outcome()) :: :ok
  # Done, or more waiting: the next tick picks the host up again at once.
  def record(host, :idle), do: succeeded(host)
  def record(host, {:ok, _}), do: succeeded(host)

  # The host said it is busy: leave it alone for as long as it asked (plus a
  # little jitter so declined hosts do not return in the same instant). Not a
  # failure.
  def record(host, {:declined, secs}) do
    delay = secs * 1_000 + :rand.uniform(1_000)
    ensure_host(host)
    set_next(host, delay)
    :ok
  end

  def record(host, {:error, reason}) do
    ensure_host(host)

    from(h in "pull_hosts", where: h.host == ^host)
    |> Repo.update_all(inc: [failures: 1], set: [last_error: String.slice(inspect(reason), 0, 300)])

    failures = Repo.one(from(h in "pull_hosts", where: h.host == ^host, select: h.failures))
    set_next(host, backoff_ms(failures))
    :ok
  end

  defp succeeded(host) do
    ensure_host(host)
    now = NaiveDateTime.utc_now()

    from(h in "pull_hosts", where: h.host == ^host)
    |> Repo.update_all(set: [next_pull_at: now, failures: 0, last_ok_at: now, last_error: nil])

    :ok
  end

  # A row for `host` to update; one that is already there is left as it is.
  defp ensure_host(host) do
    Repo.insert_all(
      "pull_hosts",
      [%{host: host, next_pull_at: NaiveDateTime.utc_now(), failures: 0}],
      on_conflict: :nothing,
      conflict_target: [:host]
    )
  end

  defp set_next(host, delay_ms) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), delay_ms, :millisecond)

    from(h in "pull_hosts", where: h.host == ^host)
    |> Repo.update_all(set: [next_pull_at: at])
  end

  @doc false
  def pending_count, do: length(Notify.pending_hosts(10_000))
end
