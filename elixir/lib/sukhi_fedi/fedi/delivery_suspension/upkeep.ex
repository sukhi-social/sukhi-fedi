# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Upkeep do
  @moduledoc """
  Keeps the delivery worker's copy of the notices true to the store.

    * On start it reads every notice from the store into the cache
      (`SukhiShared.DeliverySuspension.Cache`), retrying while the graph is not
      ready. A restart therefore changes nothing: an inbox that was resting
      rests until the same time, because the time is in the notice.
    * Every hour it forgets what can no longer be accepted (`Store.sweep/2`,
      which moves each controller's cutoff past what it drops) and reads the
      store again.

  The timer is only a wake-up. Nothing is decided by it: the worker asks the
  gate with the clock each time it is about to send.
  """

  use GenServer

  require Logger

  alias SukhiFedi.Fedi.DeliverySuspension.Store
  alias SukhiShared.DeliverySuspension.{Cache, Policy}

  @retry_ms 5_000
  @tick_ms 3_600_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Read the store into the cache now."
  @spec reload() :: :ok | {:error, term()}
  def reload, do: GenServer.call(__MODULE__, :reload, 30_000)

  @doc "Forget what is past its time, then read the store again."
  @spec sweep(DateTime.t()) :: %{notices: non_neg_integer(), pending: non_neg_integer()}
  def sweep(now \\ DateTime.utc_now()), do: GenServer.call(__MODULE__, {:sweep, now}, 30_000)

  @impl GenServer
  def init(opts) do
    {:ok, %{policy: Keyword.get(opts, :policy, Policy.default()), timer: nil}, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state), do: {:noreply, load_or_retry(state)}

  @impl GenServer
  def handle_call(:reload, _from, state) do
    {:reply, load(), state}
  end

  def handle_call({:sweep, now}, _from, state) do
    report = Store.sweep(now, state.policy)
    _ = load()
    {:reply, report, state}
  end

  @impl GenServer
  def handle_info(:retry, state), do: {:noreply, load_or_retry(state)}

  def handle_info(:tick, state) do
    report = Store.sweep(DateTime.utc_now(), state.policy)

    if report.notices + report.pending > 0,
      do: Logger.info("delivery_suspension: forgot #{inspect(report)}")

    {:noreply, load_or_retry(state)}
  end

  defp load_or_retry(state) do
    case load() do
      :ok ->
        Process.send_after(self(), :tick, @tick_ms)

      {:error, reason} ->
        Logger.warning("delivery_suspension: cache not loaded (#{inspect(reason)}); retrying")
        Process.send_after(self(), :retry, @retry_ms)
    end

    state
  end

  defp load do
    with {:ok, notices} <- Store.all_notices(), do: Cache.replace(notices)
  end
end
