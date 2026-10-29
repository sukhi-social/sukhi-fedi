# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   DTLV=/path/to/dtlv DB_DIR=/tmp/x N=200000 [XMX=256m] elixir bench.exs
#
# Loads N "jobs" through the Port, then runs a mixed claim/finish/query loop,
# printing the dtlv child's RSS (VmRSS / VmHWM) at each stage.
Code.require_file("datalevin_port.ex", __DIR__)

dtlv = System.fetch_env!("DTLV")
dir = System.fetch_env!("DB_DIR")
n = String.to_integer(System.get_env("N", "200000"))
secs = String.to_integer(System.get_env("SECS", "20"))
runtime = case System.get_env("XMX") do nil -> []; x -> ["-Xmx" <> x] end

{:ok, _} = DatalevinPort.start_link(dtlv: dtlv, name: DatalevinPort, runtime_args: runtime)
pid = DatalevinPort.os_pid()

rss = fn ->
  {:ok, s} = File.read("/proc/#{pid}/status")
  g = fn k -> Regex.run(~r/#{k}:\s+(\d+) kB/, s) |> Enum.at(1) |> String.to_integer() |> div(1024) end
  "RSS=#{g.("VmRSS")}MB (anon #{g.("RssAnon")} + file #{g.("RssFile")}) peak=#{g.("VmHWM")}MB"
end

ms = fn f -> {t, r} = :timer.tc(f); {t / 1000, r} end
tool = &DatalevinPort.tool/2
IO.puts("n=#{n} xmx=#{inspect(runtime)}  child pid=#{pid}")

{:ok, %{"database" => db}} =
  tool.("open_database", %{
    "dir" => dir, "create" => true,
    "schema" => %{
      ":job/id" => %{":db/valueType" => ":db.type/long", ":db/unique" => ":db.unique/identity"},
      ":job/host" => %{":db/valueType" => ":db.type/long"},
      ":job/state" => %{":db/valueType" => ":db.type/keyword"}}})
IO.puts("opened: #{rss.()}")

job = fn id -> %{":job/id" => id, ":job/host" => rem(id, 1000), ":job/state" => ":available"} end

# A. single-entity transactions through the Port
{t, _} = ms.(fn -> for i <- 1..500, do: {:ok, _} = tool.("transact", %{"database" => db, "txData" => [job.(-i)]}) end)
IO.puts("A. 500 single tx: #{Float.round(t / 500, 2)} ms/tx (#{round(500_000 / t)} tx/s)   #{rss.()}")

# B. bulk load in batches
# transact echoes every datom back; the MCP layer rejects results over 10000 items.
batch = 500
{t, _} = ms.(fn ->
  for b <- 0..(div(n, batch) - 1) do
    {:ok, _} = tool.("transact", %{"database" => db, "txData" => for(i <- (b * batch)..(b * batch + batch - 1), do: job.(i))})
    if rem(b + 1, max(div(n, batch * 5), 1)) == 0, do: IO.puts("   loaded #{(b + 1) * batch}: #{rss.()}")
  end
end)
IO.puts("B. load #{n} in #{round(t)} ms (#{round(n * 1000 / t)} entities/s)   #{rss.()}")

# C. read queries
q_host = "[:find ?id :where [?e :job/host 7] [?e :job/id ?id] [?e :job/state :available]]"
{t, _} = ms.(fn -> for _ <- 1..200, do: {:ok, _} = tool.("query", %{"database" => db, "query" => q_host}) end)
IO.puts("C. 200 host queries (~#{div(n, 1000)} rows each): #{Float.round(t / 200, 2)} ms/query   #{rss.()}")
{t, {:ok, %{"result" => c}}} = ms.(fn -> tool.("query", %{"database" => db, "query" => "[:find (count ?e) . :where [?e :job/state :available]]"}) end)
IO.puts("   count available = #{inspect(c)} in #{Float.round(t, 1)} ms   #{rss.()}")

# D. mixed steady state: claim (flip to :running) + finish (retract) + read, for SECS seconds
deadline = System.monotonic_time(:millisecond) + secs * 1000
{ops, _} =
  Stream.iterate(0, &(&1 + 1))
  |> Enum.reduce_while({0, 0}, fn i, {ops, cur} ->
    if System.monotonic_time(:millisecond) > deadline do
      {:halt, {ops, cur}}
    else
      id = rem(i * 7919, n)
      {:ok, _} = tool.("transact", %{"database" => db, "txData" => [%{":job/id" => id, ":job/state" => ":running"}]})
      {:ok, _} = tool.("query", %{"database" => db, "query" => "[:find ?id :where [?e :job/host #{rem(id, 1000)}] [?e :job/id ?id] [?e :job/state :available]]"})
      {:cont, {ops + 2, cur}}
    end
  end)
IO.puts("D. mixed claim+query loop #{secs}s: #{ops} ops (#{div(ops, secs)} ops/s)   #{rss.()}")
IO.puts("db size on disk: #{elem(System.cmd("du", ["-sh", dir]), 0) |> String.trim()}")
