# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

config :sukhi_fedi, SukhiFedi.Repo,
  database: "sukhi_fedi",
  username: "postgres",
  password: "postgres",
  hostname: "localhost"

config :sukhi_fedi, ecto_repos: [SukhiFedi.Repo]

# os_mon's disksup rescans every 30 min by default, so /admin/system
# would show no disk data for half an hour after each boot. A 1-minute
# rescan is plenty fresh for an admin page and costs almost nothing.
config :os_mon, disk_space_check_interval: 1

config :sukhi_fedi, Oban,
  repo: SukhiFedi.Repo,
  queues: [monitor: 5, inbound_archive: 10, outbound_archive: 10, publish: 5, preview: 3],
  plugins: [
    # NodeInfo monitor poll every 10 minutes. PollCoordinator enumerates
    # due MonitoredInstances and enqueues one PollWorker per instance.
    {Oban.Plugins.Cron,
     crontab: [
       {"*/10 * * * *", SukhiFedi.Addons.NodeinfoMonitor.PollCoordinator},
       # Daily read-only archive health check (counts + S3 HEAD of the
       # latest inbound original). Logs a WARNING if the archive drifted.
       {"30 3 * * *", SukhiFedi.Maintenance.ArchiveIntegrity}
     ]}
  ]

config :sukhi_fedi, SukhiFedi.PromEx,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled,
  metrics_server: :disabled

# Host-resource history sampler (SukhiFedi.Metrics.Sampler → metric_samples).
# One row per interval; rows older than retention_days are pruned daily.
# The read endpoint (/api/metrics) is gated by :metrics_token, set from
# METRICS_TOKEN in runtime.exs.
config :sukhi_fedi, :metrics,
  sample_interval_ms: 60_000,
  retention_days: 90

# Rate limiter (per-peer ETS buckets).
config :hammer,
  backend:
    {Hammer.Backend.ETS,
     [
       expiry_ms: 60_000 * 60 * 4,
       cleanup_interval_ms: 60_000 * 10
     ]}

import_config "#{config_env()}.exs"
