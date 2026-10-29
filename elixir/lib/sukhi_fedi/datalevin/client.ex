# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Client do
  @moduledoc """
  One native `dtlv mcp -w` child, spoken to over a Port.

  `dtlv` is Datalevin's GraalVM native binary: no JVM, no Clojure client.
  `mcp -w` is JSON-RPC on stdio. This GenServer owns the child and one open
  database; every call is serialised through it, which matches the engine
  (LMDB has a single writer) and means a read waits behind a write. A crash
  of the child cannot take the BEAM down: pending callers get
  `{:error, :dtlv_exited}`, the server stops, and the supervisor starts a
  new child that reopens the same directory (WAL replay included).

  Values written to a database are `t:term/0`s that JSON can carry; see
  `SukhiFedi.Datalevin.Edn` for the two oddities (big integers, sets).
  """

  use GenServer

  alias SukhiFedi.Datalevin.{Config, Edn}

  @max_line 16_000_000

  # ------------------------------------------------------------------ API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Run Datalog transaction data. Returns `{:ok, tempids}`."
  @spec transact(GenServer.server(), [term()]) :: {:ok, map()} | {:error, term()}
  def transact(server \\ __MODULE__, tx_data) do
    with {:ok, r} <- call(server, :transact, %{"txData" => tx_data}) do
      {:ok, tempids(r)}
    end
  end

  @doc "Run a Datalog query (EDN text). Returns the decoded result."
  @spec query(GenServer.server(), String.t()) :: {:ok, term()} | {:error, term()}
  def query(server \\ __MODULE__, edn) do
    with {:ok, %{"result" => r}} <- call(server, :query, %{"query" => edn}) do
      {:ok, Edn.decode(r)}
    end
  end

  @doc "Pull one entity by lookup ref or entity id; `nil` when absent."
  @spec pull(GenServer.server(), term()) :: {:ok, map() | nil} | {:error, term()}
  def pull(server \\ __MODULE__, eid) do
    case call(server, :pull, %{"selector" => ["*"], "eid" => eid}) do
      {:ok, %{"result" => r}} -> {:ok, Edn.decode(r)}
      {:error, %{"error" => "Nothing found" <> _}} -> {:ok, nil}
      {:error, _} = e -> e
    end
  end

  @doc """
  Several queries in one go: every request is written to the child before
  any answer is read, so N independent reads cost one round trip of waiting
  instead of N. Answers come back in the order asked. This is how a
  timeline is fetched — the follow edges, the notes, the boosts and the
  authors as separate small queries sent together — instead of one
  many-way join.
  """
  @spec query_many(GenServer.server(), [String.t()]) :: [{:ok, term()} | {:error, term()}]
  def query_many(server \\ __MODULE__, edns)
  # Nothing asked, nothing sent: a batch of none would never be answered.
  def query_many(_server, []), do: []

  def query_many(server, edns) do
    reqs = Enum.map(edns, &{:query, %{"query" => &1}})

    case GenServer.call(server, {:many, reqs}, :infinity) do
      results when is_list(results) ->
        Enum.map(results, fn
          {:ok, %{"result" => r}} -> {:ok, Edn.decode(r)}
          {:error, _} = e -> e
        end)

      {:error, _} = e ->
        Enum.map(edns, fn _ -> e end)
    end
  catch
    :exit, _ -> Enum.map(edns, fn _ -> {:error, :dtlv_down} end)
  end

  @doc "The child's OS pid, for sampling its memory."
  @spec os_pid(GenServer.server()) :: pos_integer()
  def os_pid(server \\ __MODULE__), do: GenServer.call(server, :os_pid)

  @doc "Raw tool call (without the `datalevin_` prefix) against the open database."
  @spec call(GenServer.server(), atom(), map()) :: {:ok, map()} | {:error, term()}
  def call(server \\ __MODULE__, tool, args) do
    GenServer.call(server, {:tool, tool, args}, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, :dtlv_down}
    :exit, {reason, _} -> {:error, {:dtlv_down, reason}}
  end

  # ----------------------------------------------------------- GenServer

  @impl true
  def init(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.current/0)
    schema = Keyword.get(opts, :schema, %{})
    Process.flag(:trap_exit, true)

    File.mkdir_p!(config.dir)

    exe =
      System.find_executable(config.bin) ||
        raise "dtlv not found: #{inspect(config.bin)} (DATALEVIN_BIN)"

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        {:line, @max_line},
        {:args, Config.runtime_args(config) ++ ["mcp", "-w"]}
      ])

    state = %{port: port, config: config, next: 1, pending: %{}, batches: %{}, buf: [], db: nil}

    with {:ok, state} <- handshake(state),
         {:ok, state} <- open(state, schema) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:dtlv_open_failed, reason}}
    end
  end

  # Synchronous startup: the first two exchanges happen before we serve calls.
  defp handshake(state) do
    {id, state} = next_id(state)

    send_json(state, %{
      jsonrpc: "2.0",
      id: id,
      method: "initialize",
      params: %{
        protocolVersion: "2024-11-05",
        capabilities: %{},
        clientInfo: %{name: "sukhi-fedi", version: "1"}
      }
    })

    with {:ok, _} <- await(state, id) do
      send_json(state, %{jsonrpc: "2.0", method: "notifications/initialized"})
      {:ok, state}
    end
  end

  defp open(state, schema) do
    {id, state} = next_id(state)

    send_json(state, %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{
        name: "datalevin_open_database",
        arguments: %{
          "dir" => state.config.dir,
          "create" => true,
          "schema" => schema,
          "opts" => Config.open_opts(state.config)
        }
      }
    })

    with {:ok, %{"database" => db}} <- await(state, id) do
      {:ok, %{state | db: db}}
    end
  end

  defp await(state, id, buf \\ []) do
    receive do
      {port, {:data, {:noeol, chunk}}} when port == state.port ->
        await(state, id, [buf, chunk])

      {port, {:data, {:eol, line}}} when port == state.port ->
        msg = :json.decode(IO.iodata_to_binary([buf, line]))

        if msg["id"] == id, do: result(msg), else: await(state, id)

      {port, {:exit_status, s}} when port == state.port ->
        {:error, {:exit_status, s}}
    after
      state.config.timeout_ms * 4 -> {:error, :timeout}
    end
  end

  @impl true
  def handle_call(:os_pid, _from, state),
    do: {:reply, Port.info(state.port, :os_pid) |> elem(1), state}

  def handle_call({:tool, name, args}, from, state) do
    {id, state} = next_id(state)

    send_json(state, %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{
        name: "datalevin_" <> Atom.to_string(name),
        arguments: Map.put(args, "database", state.db)
      }
    })

    timer = Process.send_after(self(), {:timeout, id}, state.config.timeout_ms)
    {:noreply, %{state | pending: Map.put(state.pending, id, {from, timer})}}
  end

  def handle_call({:many, reqs}, from, state) do
    ref = make_ref()

    {ids, state} =
      Enum.map_reduce(reqs, state, fn {name, args}, st ->
        {id, st} = next_id(st)

        send_json(st, %{
          jsonrpc: "2.0",
          id: id,
          method: "tools/call",
          params: %{
            name: "datalevin_" <> Atom.to_string(name),
            arguments: Map.put(args, "database", st.db)
          }
        })

        {id, st}
      end)

    batch = %{from: from, ids: ids, got: %{}}
    timer = Process.send_after(self(), {:timeout_many, ref}, state.config.timeout_ms)
    pending = Enum.reduce(ids, state.pending, &Map.put(&2, &1, {:many, ref}))
    {:noreply, %{state | pending: pending, batches: Map.put(state.batches, ref, {batch, timer})}}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buf: [state.buf, chunk]}}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    msg = :json.decode(IO.iodata_to_binary([state.buf, line]))
    state = %{state | buf: []}

    case Map.pop(state.pending, msg["id"]) do
      {nil, _} ->
        {:noreply, state}

      {{:many, ref}, pending} ->
        {:noreply, collect(%{state | pending: pending}, ref, msg)}

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, result(msg))
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:timeout_many, ref}, state) do
    case Map.pop(state.batches, ref) do
      {nil, _} ->
        {:noreply, state}

      {{b, _}, batches} ->
        GenServer.reply(b.from, {:error, :timeout})
        {:noreply, %{state | batches: batches, pending: Map.drop(state.pending, b.ids)}}
    end
  end

  # A call that outlived its budget: tell the caller, forget the id. The
  # child may still finish the work (a write that timed out can have landed).
  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{:many, _}, _} ->
        {:noreply, state}

      {{from, _}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Enum.each(state.pending, fn
      {_, {:many, _}} -> :ok
      {_, {from, _}} -> GenServer.reply(from, {:error, :dtlv_exited})
    end)

    Enum.each(state.batches, fn {_, {b, _}} -> GenServer.reply(b.from, {:error, :dtlv_exited}) end)

    {:stop, {:dtlv_exited, status}, %{state | pending: %{}}}
  end

  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    # Closing stdin makes `dtlv mcp` flush and exit; the WAL is replayed on
    # the next start either way.
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  # --------------------------------------------------------------- helpers

  defp collect(state, ref, msg) do
    {{b, timer}, rest} = Map.pop(state.batches, ref)
    b = %{b | got: Map.put(b.got, msg["id"], result(msg))}

    if map_size(b.got) == length(b.ids) do
      Process.cancel_timer(timer)
      GenServer.reply(b.from, Enum.map(b.ids, &Map.fetch!(b.got, &1)))
      %{state | batches: rest}
    else
      %{state | batches: Map.put(rest, ref, {b, timer})}
    end
  end

  defp result(%{"error" => err}), do: {:error, err}
  defp result(%{"result" => %{"isError" => true} = r}), do: {:error, error_body(r)}
  defp result(%{"result" => %{"structuredContent" => s}}), do: {:ok, s}
  defp result(%{"result" => r}), do: {:ok, r}

  defp error_body(%{"structuredContent" => %{"error" => _} = s}), do: s
  defp error_body(r), do: r

  defp tempids(%{"result" => %{"tempids" => t}}), do: t |> Edn.decode() |> normalize_tempids()
  defp tempids(_), do: %{}

  defp normalize_tempids(m) when is_map(m), do: m
  defp normalize_tempids(_), do: %{}

  defp next_id(%{next: n} = s), do: {n, %{s | next: n + 1}}

  defp send_json(%{port: port}, map), do: Port.command(port, [:json.encode(map), ?\n])
end
