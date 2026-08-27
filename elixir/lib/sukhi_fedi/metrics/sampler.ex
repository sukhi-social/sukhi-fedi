# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Metrics.Sampler do
  @moduledoc """
  Writes one `SukhiFedi.Metrics` row per interval so the host-resource
  series keeps accruing, and trims the tail once a day so it never grows
  without bound.

  Config (`config :sukhi_fedi, :metrics`):

    * `:sample_interval_ms` — gap between samples. `nil` means *don't
      auto-sample* (the test env sets this; `Metrics.record/0` is still
      called directly in tests).
    * `:retention_days` — older rows are pruned (default 90).

  `:cpu_sup.util/0` reports utilisation since the previous call, so the
  first tick covers the whole "since boot" window. We prime it once at
  init and discard that reading, exactly like the SSE stream does.
  """

  use GenServer

  require Logger

  alias SukhiFedi.Metrics
  alias SukhiFedi.SystemMetrics

  @default_retention_days 90
  @prune_interval_ms 24 * 60 * 60 * 1_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    cfg = Application.get_env(:sukhi_fedi, :metrics, [])
    interval = Keyword.get(cfg, :sample_interval_ms)

    if is_integer(interval) and interval > 0 do
      # Prime cpu_sup so the first stored sample covers one interval, not
      # an unbounded window.
      _ = SystemMetrics.cpu_util()
      schedule(:sample, interval)
      schedule(:prune, @prune_interval_ms)
      {:ok, %{interval: interval, retention_days: retention_days(cfg)}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:sample, state) do
    try do
      Metrics.record() |> alert_on_dlq()
    rescue
      e -> Logger.warning("metrics sampler: record failed: #{Exception.message(e)}")
    end

    schedule(:sample, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune, state) do
    try do
      deleted = Metrics.prune(state.retention_days)
      if deleted > 0, do: Logger.info("metrics sampler: pruned #{deleted} old rows")
    rescue
      e -> Logger.warning("metrics sampler: prune failed: #{Exception.message(e)}")
    end

    schedule(:prune, @prune_interval_ms)
    {:noreply, state}
  end

  # A non-empty dead-letter queue means outbound federation is failing for
  # someone. Surface it on every tick it's non-zero — the log is the alert
  # (the depth also lands in the metric_samples series for /admin/system
  # and offline analysis).
  defp alert_on_dlq(%{outbox_dlq_depth: n}) when is_integer(n) and n > 0 do
    Logger.warning("metrics sampler: #{n} discarded job(s) — outbound federation is failing")
  end

  defp alert_on_dlq(_), do: :ok

  defp retention_days(cfg) do
    case Keyword.get(cfg, :retention_days, @default_retention_days) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_retention_days
    end
  end

  defp schedule(msg, ms), do: Process.send_after(self(), msg, ms)
end
