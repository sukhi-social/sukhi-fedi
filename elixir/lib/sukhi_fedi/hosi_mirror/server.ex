# SPDX-License-Identifier: AGPL-3.0-or-later
if Code.ensure_loaded?(SukhiHosi.Tail) do
  defmodule SukhiFedi.HosiMirror.Server do
    @moduledoc """
    Opens hosigraph and, every `@tick`, runs one round of `SukhiHosi.Tail` over `SukhiFedi.Repo`.
    A round that fails (hosigraph or the store is down, a row it cannot read) is logged and tried
    again on the next tick: the cursors are in hosigraph and only move past what is written.

    The last step of a round, the sweep (what left the store), is the one that looks at what is
    already there, so it runs at most every `@sweep_every`, not on each tick.
    """

    use GenServer

    require Logger

    alias SukhiFedi.HosiMirror.RepoSource

    @tick :timer.seconds(2)
    @sweep_every :timer.seconds(10)

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @doc "Run one round now, in the caller's wait (what a tick does; tests call it)."
    def sync_now(server \\ __MODULE__), do: GenServer.call(server, :sync, :timer.minutes(5))

    @impl true
    def init(opts) do
      dir = Keyword.get_lazy(opts, :dir, &dir/0)
      File.mkdir_p!(dir)
      bin = Keyword.get_lazy(opts, :bin, fn -> System.get_env("DATALEVIN_BIN", "dtlv") end)
      # `terminate/2` closes hosigraph, so a stop (a deploy) leaves its files as a clean close does
      Process.flag(:trap_exit, true)
      {:ok, db} = SukhiHosi.Store.start_link(dir: dir, dtlv: bin)
      schedule(Keyword.get(opts, :tick, @tick))

      {:ok,
       %{
         db: db,
         domain: Keyword.get_lazy(opts, :domain, &SukhiFedi.Config.domain!/0),
         tick: Keyword.get(opts, :tick, @tick),
         sweep_every: Keyword.get(opts, :sweep_every, @sweep_every),
         swept_at: nil
       }}
    end

    @impl true
    def handle_call(:sync, _from, state) do
      {report, state} = run_round(state, true)
      {:reply, report, state}
    end

    @impl true
    def handle_info(:tick, state) do
      {_report, state} = run_round(state, false)
      schedule(state.tick)
      {:noreply, state}
    end

    # hosigraph (linked to us) went away: we are of no use without it; the supervisor starts us again
    def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

    @impl true
    def terminate(_reason, %{db: db}) do
      Hosi.stop(db)
    catch
      :exit, _ -> :ok
    end

    # `force?`: the sweep too, whatever the time (what a caller of `sync_now` asks for)
    defp run_round(%{db: db, domain: domain} = state, force?) do
      now = System.monotonic_time(:millisecond)
      sweep? = force? or state.swept_at == nil or now - state.swept_at >= state.sweep_every
      report = SukhiHosi.Tail.sync(db, {RepoSource, nil}, domain: domain, sweep: sweep?)
      {report, if(sweep?, do: %{state | swept_at: now}, else: state)}
    rescue
      e ->
        Logger.warning("hosi mirror: round failed: #{Exception.message(e)}")
        {{:error, e}, state}
    end

    defp schedule(:infinity), do: :ok
    defp schedule(ms), do: Process.send_after(self(), :tick, ms)

    defp dir do
      System.get_env("SUKHI_HOSI_DIR") || Path.join(System.get_env("DATALEVIN_DIR", "/var/lib/sukhi/datalevin"), "hosi")
    end
  end
end
