# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Compare do
  @moduledoc "Run every scenario through push and pull and print the numbers."
  use Mix.Task

  alias PullFederation.{Compare, FanOut, Flood, NotifyCost}

  @shortdoc "Compare push and pull federation models"

  @impl true
  def run(_args) do
    IO.puts("# Receiver B (Compare)")

    for sc <- Compare.scenarios() do
      IO.puts("\n== #{sc.name}")

      for model <- [:push, :pull] do
        r = Compare.run(model, sc)

        IO.puts(
          "  #{String.pad_trailing(to_string(r.model), 5)}" <>
            " delivered=#{r.delivered} reqs=#{r.requests_to_b} failed=#{r.failed_requests}" <>
            " peak/s=#{r.peak_requests_per_s} giveups=#{r.give_ups} lostnotes=#{r.lost_notifications}" <>
            " declines=#{r.pull_declines} p50=#{r.latency_p50_ms} p99=#{r.latency_p99_ms} max=#{r.latency_max_ms}"
        )
      end
    end

    IO.puts("\n# Origin A fan-out (FanOut)")

    for opts <- fan_out_cases() do
      IO.puts("\n== #{opts[:domains]} domains, #{opts[:posts]} posts in 10 s")

      for model <- [:push, :pull] do
        r = FanOut.run(model, opts)

        IO.puts(
          "  #{String.pad_trailing(to_string(model), 5)}" <>
            " out_reqs=#{r.requests_out} in_reqs=#{r.inbound_requests} sigs=#{r.signatures}" <>
            " db_writes=#{r.db_writes} db_queries=#{r.db_queries} rows=#{r.rows_read}" <>
            " peak_queue=#{r.peak_queue_entries} MB_out=#{r.megabytes_out}" <>
            " cost=#{r.origin_cost_units} (#{r.units_per_post}/post)"
        )
      end
    end

    flood_report()
    rate_report()

    IO.puts("\n# Notification form (NotifyCost): inline vs bucket snapshots")

    for {name, o} <- [
          {"each domain follows 100 of 2000 actors, 200 posts", []},
          {"each domain follows 1500 of 2000, 1000 posts, 100 domains",
           [follow_k: 1500, posts: 1000, domains: 100]}
        ] do
      IO.puts("\n== #{name}")

      for {label, inline_max} <- [{"inline", 100_000}, {"hybrid <=5", 5}, {"snapshot", 0}] do
        r = NotifyCost.run(inline_max, o)

        IO.puts(
          "  #{String.pad_trailing(label, 10)} notes=#{r.notifications} avg_note=#{r.avg_notification_bytes}B" <>
            " fetches=#{r.snapshot_fetches} fetch_bytes=#{r.snapshot_bytes}" <>
            " renders=#{r.origin_renders} wire_total=#{r.total_wire_bytes}"
        )
      end
    end
  end

  defp flood_report do
    IO.puts("\n# Forged notifications (Flood.fake_notifications)")

    for r <- Flood.fake_notifications() do
      IO.puts(
        "  #{r.attack}: accepted=#{r.accepted}/#{r.sent} pulls=#{r.pulls_caused} state_growth=#{r.state_growth}"
      )
    end

    IO.puts("\n# Pull stampede (Flood.stampede), 8 stream slots, 400 ms per stream")

    for {name, o} <- [
          {"1000 domains, receivers guess a backoff", [domains: 1000, reserve_ms: 0]},
          {"1000 domains, guess, no jitter (horizon 300 s)",
           [domains: 1000, reserve_ms: 0, jitter: :none, horizon_ms: 300_000]},
          {"1000 domains, appointments", [domains: 1000]},
          {"1000 domains, appointments + lazy start 30 s",
           [domains: 1000, lazy_spread_ms: 30_000]},
          {"5000 domains, guess", [domains: 5000, reserve_ms: 0]},
          {"5000 domains, appointments", [domains: 5000]},
          {"1000 receivers hammering every 100 ms (120 s)",
           [domains: 1000, hammer: true, horizon_ms: 120_000]}
        ] do
      r = Flood.stampede(o)

      IO.puts(
        "  #{String.pad_trailing(name, 50)} converged=#{r.converged} reqs=#{r.pull_requests_at_origin}" <>
          " declined=#{r.declined} peak/s=#{r.peak_requests_per_s} p50=#{r.p50_converged_ms} last=#{r.last_converged_ms}" <>
          " cost=#{r.origin_cost_units}"
      )
    end
  end

  defp rate_report do
    IO.puts("\n# Posts per domain per 10 min: who is cheaper (FanOut.per_domain, quiet 3 s)")

    for posts <- [1, 10, 100, 200, 300, 600, 2_000] do
      r = FanOut.per_domain(posts, 600_000)
      f = fn x -> :erlang.float_to_binary(x * 1.0, decimals: 1) end

      IO.puts(
        "  posts=#{String.pad_leading(to_string(posts), 5)} posts/notif=#{f.(r.posts_per_notification)}" <>
          " origin push/pull=#{f.(r.push_origin / r.pull_origin)}x receiver push/pull=#{f.(r.push_b / r.pull_b)}x"
      )
    end
  end

  def fan_out_cases do
    [
      [domains: 100, posts: 10],
      [domains: 1_000, posts: 10],
      [domains: 1_000, posts: 100],
      [domains: 5_000, posts: 100]
    ]
  end
end
