# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.Cache do
  @moduledoc """
  The notices that can put a delivery on hold, kept in ETS so the delivery
  worker can ask "is this inbox resting?" without a database round trip.

  It is a **copy**, never the record. The gateway keeps the notices in the
  graph store (`SukhiFedi.Fedi.DeliverySuspension.Store`), writes here after
  the store has taken a write, and rebuilds this table from the store when it
  starts, so a restart changes nothing: the same inbox rests until the same
  time. Only *active* notices are kept; a cancelled one is dropped, because it
  is never in effect.

  Reads go straight to ETS from any process and answer `[]` when the table is
  not there. That is the whole story for a delivery node that is not in the
  gateway's VM (the split deployment): it has no table, so it never holds a
  delivery. When in doubt, deliver.

  The table is `:ordered_set` keyed `{kind, target, id}`, so asking about one
  inbox, or one origin, is a range over its own prefix and does not scan the
  rest.
  """

  use GenServer

  alias SukhiShared.DeliverySuspension.{Notice, Origin}

  @table :sukhi_delivery_suspension

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Child spec; one per VM (the gateway starts it when the graph store is on)."
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}

  @doc "The notices that could apply to a POST to `delivery_url`: its inbox notices and its origin's."
  @spec candidates(term()) :: [Notice.t()]
  def candidates(delivery_url) when is_binary(delivery_url) do
    with {:ok, origin} <- Origin.of_delivery_url(delivery_url),
         true <- table?() do
      select(:inbox, delivery_url) ++ select(:origin, origin)
    else
      _ -> []
    end
  end

  def candidates(_), do: []

  @doc "Every notice held (admin screen, tests)."
  @spec all() :: [Notice.t()]
  def all do
    if table?(), do: :ets.select(@table, [{{:_, :"$1"}, [], [:"$1"]}]), else: []
  end

  @doc "Keep `notice` if it is active, forget it if it is not."
  @spec put(Notice.t()) :: :ok
  def put(%Notice{} = notice), do: call({:put, notice})

  @doc "Replace everything with `notices` (the rebuild after a start or a sweep)."
  @spec replace([Notice.t()]) :: :ok
  def replace(notices) when is_list(notices), do: call({:replace, notices})

  # A write while the owner is not running is not an error: the table is a
  # copy, and the next start rebuilds it from the store.
  defp call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _ -> :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp select(kind, target) do
    :ets.select(@table, [{{{kind, target, :_}, :"$1"}, [], [:"$1"]}])
  end

  defp key(%Notice{target_kind: kind, target: target, id: id}), do: {kind, target, id}

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, :ordered_set, read_concurrency: true])
    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:put, %Notice{status: :active} = notice}, _from, state) do
    :ets.insert(@table, {key(notice), notice})
    {:reply, :ok, state}
  end

  def handle_call({:put, %Notice{} = notice}, _from, state) do
    :ets.delete(@table, key(notice))
    {:reply, :ok, state}
  end

  def handle_call({:replace, notices}, _from, state) do
    :ets.delete_all_objects(@table)
    for %Notice{status: :active} = n <- notices, do: :ets.insert(@table, {key(n), n})
    {:reply, :ok, state}
  end
end
