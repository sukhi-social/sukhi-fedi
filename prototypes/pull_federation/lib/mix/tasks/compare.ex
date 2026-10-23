# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Compare do
  @moduledoc "Run every scenario through push and pull and print the numbers."
  use Mix.Task

  alias PullFederation.Compare

  @shortdoc "Compare push and pull federation models"

  @impl true
  def run(_args) do
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
  end
end
