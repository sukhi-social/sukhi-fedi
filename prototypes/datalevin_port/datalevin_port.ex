# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prototype: drive a native `dtlv mcp` process from Elixir through a Port.
#
# `dtlv` is Datalevin's GraalVM native binary; `dtlv mcp -w` speaks JSON-RPC
# (MCP) on stdio and exposes open_database / transact / query / pull. No JVM,
# no Clojure client, and a crash of the child cannot take the BEAM down.
#
# One GenServer owns one child. Calls are serialised through it, so this is a
# latency/memory probe, not a pool.

defmodule DatalevinPort do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Call an MCP tool; returns {:ok, structured_content} or {:error, reason}."
  def tool(server \\ __MODULE__, name, args, timeout \\ 120_000) do
    GenServer.call(server, {:tool, name, args}, timeout)
  end

  @doc "OS pid of the child, for RSS sampling."
  def os_pid(server \\ __MODULE__), do: GenServer.call(server, :os_pid)

  @impl true
  def init(opts) do
    exe = Keyword.fetch!(opts, :dtlv)
    flags = if Keyword.get(opts, :write, true), do: ["-w"], else: []
    # GraalVM native images take runtime heap flags (e.g. "-Xmx128m") before the
    # program arguments.
    runtime = Keyword.get(opts, :runtime_args, [])

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        {:line, 16_000_000},
        {:args, runtime ++ ["mcp" | flags]}
      ])

    state = %{port: port, next: 1, pending: %{}, buf: ""}
    {id, state} = next_id(state)

    send_json(state, %{
      jsonrpc: "2.0",
      id: id,
      method: "initialize",
      params: %{
        protocolVersion: "2024-11-05",
        capabilities: %{},
        clientInfo: %{name: "sukhi-datalevin-port", version: "0"}
      }
    })

    send_json(state, %{jsonrpc: "2.0", method: "notifications/initialized"})
    {:ok, %{state | pending: Map.put(state.pending, id, :init)}}
  end

  @impl true
  def handle_call(:os_pid, _from, state) do
    {:reply, Port.info(state.port, :os_pid) |> elem(1), state}
  end

  def handle_call({:tool, name, args}, from, state) do
    {id, state} = next_id(state)

    send_json(state, %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{name: "datalevin_" <> name, arguments: args}
    })

    {:noreply, %{state | pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buf: state.buf <> chunk}}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    msg = :json.decode(state.buf <> line)
    state = %{state | buf: ""}

    case Map.pop(state.pending, msg["id"]) do
      {nil, _} ->
        {:noreply, state}

      {:init, pending} ->
        {:noreply, %{state | pending: pending}}

      {from, pending} ->
        GenServer.reply(from, result(msg))
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:dtlv_exited, status}, state}
  end

  defp result(%{"error" => err}), do: {:error, err}
  defp result(%{"result" => %{"isError" => true} = r}), do: {:error, r}
  defp result(%{"result" => %{"structuredContent" => s}}), do: {:ok, s}
  defp result(%{"result" => r}), do: {:ok, r}

  defp next_id(%{next: n} = s), do: {n, %{s | next: n + 1}}

  defp send_json(%{port: port}, map) do
    Port.command(port, [:json.encode(map), ?\n])
  end
end
