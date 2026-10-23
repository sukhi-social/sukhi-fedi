# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Compare do
  @moduledoc "Run every scenario through push and pull and print the numbers."
  use Mix.Task

  alias PullFederation.{Compare, FanOut}

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
