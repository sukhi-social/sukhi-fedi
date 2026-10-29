# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Crash/restart check against a real on-disk schema.
#
#   elixir -pa _build/dev/lib/mnesia_queue/ebin bench/crash.exs write DIR   # then `kill -9`s itself
#   elixir -pa _build/dev/lib/mnesia_queue/ebin bench/crash.exs recover DIR
[mode, dir] = System.argv()
Application.put_env(:mnesia, :dir, String.to_charlist(dir))

case mode do
  "write" ->
    :ok = :mnesia.create_schema([node()])
    :ok = MnesiaQueue.setup(:disc_copies)
    now = 1_000_000
    for i <- 1..1000, do: {:ok, _} = MnesiaQueue.enqueue("h#{rem(i, 20)}.example", i, now)
    claimed = MnesiaQueue.claim(now, 30_000, limit: 100, host_limit: 100)
    [first | _] = claimed
    :ok = MnesiaQueue.complete(first.id, now)
    IO.puts("wrote 1000 jobs, claimed #{length(claimed)}, completed 1; killing the VM with SIGKILL")
    System.cmd("kill", ["-9", System.pid()])
    Process.sleep(5_000)

  "recover" ->
    :ok = MnesiaQueue.setup(:disc_copies)
    now = 1_000_000
    s = MnesiaQueue.stats()
    IO.inspect(s.by_state, label: "after restart")
    n = MnesiaQueue.lifeline(now + 30_001)
    IO.puts("lifeline recovered #{n} expired claims")
    IO.inspect(MnesiaQueue.stats().by_state, label: "after lifeline")
end
