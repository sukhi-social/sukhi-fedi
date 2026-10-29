# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   STORAGE=ram|disc SYNC=true|false N=100000 elixir -pa _build/dev/lib/mnesia_queue/ebin bench/bench.exs
#
# enqueue N jobs (1 tx each) over 1000 hosts, then claim+complete them all,
# printing throughput and BEAM / process memory.
storage = System.get_env("STORAGE", "ram")
n = String.to_integer(System.get_env("N", "100000"))
Application.put_env(:mnesia_queue, :sync, System.get_env("SYNC", "true") == "true")

if storage == "disc" do
  dir = "/tmp/claude-0/mq-bench-#{System.os_time(:microsecond)}"
  File.mkdir_p!(dir)
  Application.put_env(:mnesia, :dir, String.to_charlist(dir))
  :ok = :mnesia.create_schema([node()])
end

:ok = MnesiaQueue.setup(if storage == "disc", do: :disc_copies, else: :ram_copies)

rss = fn ->
  {:ok, s} = File.read("/proc/self/status")
  [_, kb] = Regex.run(~r/VmRSS:\s+(\d+) kB/, s)
  div(String.to_integer(kb), 1024)
end

mem = fn -> "BEAM total #{div(:erlang.memory(:total), 1_048_576)} MB, ets #{div(:erlang.memory(:ets), 1_048_576)} MB, process RSS #{rss.()} MB" end
rate = fn count, us -> "#{round(count * 1_000_000 / us)}/s (#{Float.round(us / count, 1)} µs each)" end

IO.puts("storage=#{storage} sync=#{System.get_env("SYNC", "true")} N=#{n}")
IO.puts("start: " <> mem.())

{us, _} = :timer.tc(fn -> for i <- 1..n, do: {:ok, _} = MnesiaQueue.enqueue("h#{rem(i, 1000)}.example", %{"inbox" => "https://h#{rem(i, 1000)}.example/inbox", "activity_id" => i}, 0) end)
IO.puts("enqueue:        " <> rate.(n, us))
IO.puts("after enqueue:  " <> mem.())

{us, done} =
  :timer.tc(fn ->
    Stream.repeatedly(fn ->
      jobs = MnesiaQueue.claim(0, 60_000, limit: 20, host_limit: 4)
      for j <- jobs, do: :ok = MnesiaQueue.complete(j.id, 1)
      length(jobs)
    end)
    |> Enum.take_while(&(&1 > 0))
    |> Enum.sum()
  end)
IO.puts("claim+complete: #{done} jobs, " <> rate.(done, us))
IO.puts("after drain:    " <> mem.())
{us, pruned} = :timer.tc(fn -> MnesiaQueue.prune(10_000, 1) end)
IO.puts("prune: #{pruned} jobs in #{div(us, 1000)} ms;  " <> mem.())
