# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.MetricSample do
  use Ecto.Schema

  @moduledoc """
  One host-resource snapshot at `sampled_at`. Flat numeric columns so the
  table reads like a CSV — one wide row per timestamp — which is the shape
  offline analysis (Julia) wants. See `SukhiFedi.Metrics`.
  """

  schema "metric_samples" do
    field :sampled_at, :utc_datetime_usec

    field :cpu_percent, :float
    field :load1, :float
    field :load5, :float
    field :load15, :float

    field :mem_total, :integer
    field :mem_used, :integer
    field :mem_available, :integer
    field :swap_total, :integer
    field :swap_free, :integer

    field :beam_total, :integer
    field :beam_processes, :integer
    field :beam_binary, :integer

    field :disk_total, :integer
    field :disk_used_percent, :float

    # Oban jobs that gave up (`discarded`) — mostly outbound activities
    # that never reached an inbox. NULL when `oban_jobs` can't be queried.
    field :outbox_dlq_depth, :integer
  end
end
