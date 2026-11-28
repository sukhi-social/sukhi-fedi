# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.Cache do
  @moduledoc """
  The notices that can put a delivery on hold, kept in ETS so the delivery
  worker can ask "is this inbox resting?" without a database round trip.

  It is a **copy**, never the record. The gateway keeps the notices in the
  PostgreSQL (`SukhiFedi.Fedi.DeliverySuspension.Store`), writes here after
  the store has taken a write, and rebuilds this table from the store when it
  starts, so a restart changes nothing: the same inbox rests until the same
  time. Only *active, believed* notices are kept; a cancelled or withdrawn one is
  dropped, because it is never in effect.

  Reads go straight to ETS from any process and answer `[]` when the table is
  not there. That is the whole story for a delivery node that is not in the
  gateway's VM (the split deployment): it has no table, so it never holds a
  delivery. When in doubt, deliver.

  The table is `:ordered_set` keyed `{kind, target, id}`, so asking about one
  inbox, or one origin, is a range over its own prefix and does not scan the
  rest.

  Two more things live here, because the delivery worker asks the cache and
  nothing else:

    * **Ignored notices.** An admin may choose to ignore a rest on this server
      (`ignore: ids`). The notice stays in the store, untouched; it is simply
      never kept here, so deliveries to its target go out as usual. A later
      revision of an ignored notice is ignored too (the mark is by `id`); a
      new rest has a new `id`.
    * **A budget of held deliveries per controller** (`Policy.max_held_per_controller`).
      `reserve/3` counts a delivery the first time it is held, `release/1`
      forgets it when it is sent, and a controller that is over its budget
      does not get to hold more: the delivery goes out. The counts are
      approximate by design (they are rebuilt from nothing at every
      `replace/2`, and a job that dies while held leaves its count until
      then); they bound what a controller can make us keep, nothing more.
  """

  use GenServer

  alias SukhiShared.DeliverySuspension.{Notice, Origin}

  @table :sukhi_delivery_suspension
  # `{key, controller}` for what is held, and `{controller, n}` for how many.
  @held :sukhi_delivery_suspension_held
  @counts :sukhi_delivery_suspension_counts

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Child spec; one per VM (the gateway starts it when `:delivery_suspension` is on)."
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

  @doc """
  Replace everything with `notices` (the rebuild after a start or a sweep).
  `opts[:ignore]` is the ids of the notices an admin chose to ignore; without
  it the set already held stays. The held-delivery counts start again.
  """
  @spec replace([Notice.t()], keyword()) :: :ok
  def replace(notices, opts \\ []) when is_list(notices) and is_list(opts),
    do: call({:replace, notices, Keyword.get(opts, :ignore)})

  @doc "The ids of the notices ignored here."
  @spec ignored() :: [String.t()]
  def ignored do
    GenServer.call(__MODULE__, :ignored)
  catch
    :exit, _ -> []
  end

  @doc """
  Count a delivery as held under `controller`, once: `:ok`, or `:full` when
  the controller already has `limit` held (the caller then lets it go out).
  Safe from any process; `:ok` where there is no table (nothing is held there).
  """
  @spec reserve(String.t(), term(), pos_integer()) :: :ok | :full
  def reserve(controller, key, limit) when is_binary(controller) and is_integer(limit) do
    cond do
      not held_tables?() ->
        :ok

      :ets.member(@held, key) ->
        :ok

      true ->
        n = :ets.update_counter(@counts, controller, 1, {controller, 0})

        if n > limit do
          :ets.update_counter(@counts, controller, -1)
          :full
        else
          :ets.insert(@held, {key, controller})
          :ok
        end
    end
  end

  @doc "Forget a held delivery (it is being sent). `true` if it had been held."
  @spec release(term()) :: boolean()
  def release(key) do
    with true <- held_tables?(),
         [{^key, controller}] <- :ets.lookup(@held, key) do
      :ets.delete(@held, key)
      :ets.update_counter(@counts, controller, -1)
      true
    else
      _ -> false
    end
  end

  @doc "How many deliveries each controller's notices hold back right now, as `%{controller => n}`."
  @spec held_counts() :: %{String.t() => non_neg_integer()}
  def held_counts do
    if held_tables?() do
      for {controller, n} <- :ets.tab2list(@counts), n > 0, into: %{}, do: {controller, n}
    else
      %{}
    end
  end

  # A write while the owner is not running is not an error: the table is a
  # copy, and the next start rebuilds it from the store.
  defp call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _ -> :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp held_tables?,
    do: :ets.whereis(@held) != :undefined and :ets.whereis(@counts) != :undefined

  defp select(kind, target) do
    :ets.select(@table, [{{{kind, target, :_}, :"$1"}, [], [:"$1"]}])
  end

  defp key(%Notice{target_kind: kind, target: target, id: id}), do: {kind, target, id}

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, :ordered_set, read_concurrency: true])
    # Public: the delivery workers count their own held deliveries.
    :ets.new(@held, [:named_table, :public, :set, write_concurrency: true])
    :ets.new(@counts, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{ignored: MapSet.new()}}
  end

  @impl GenServer
  def handle_call({:put, %Notice{} = notice}, _from, state) do
    if keep?(notice, state.ignored),
      do: :ets.insert(@table, {key(notice), notice}),
      else: :ets.delete(@table, key(notice))

    {:reply, :ok, state}
  end

  def handle_call({:replace, notices, ignore}, _from, state) do
    ignored = if is_list(ignore), do: MapSet.new(ignore), else: state.ignored
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@held)
    :ets.delete_all_objects(@counts)
    for n <- notices, keep?(n, ignored), do: :ets.insert(@table, {key(n), n})
    {:reply, :ok, %{state | ignored: ignored}}
  end

  def handle_call(:ignored, _from, state), do: {:reply, MapSet.to_list(state.ignored), state}

  # Only what could put a delivery on hold: active, believed (a notice
  # whose control went away is withdrawn: `accepted_at` is nil), and not
  # ignored by an admin.
  defp keep?(%Notice{id: id, status: :active, accepted_at: %DateTime{}}, ignored),
    do: not MapSet.member?(ignored, id)

  defp keep?(%Notice{}, _ignored), do: false
end
