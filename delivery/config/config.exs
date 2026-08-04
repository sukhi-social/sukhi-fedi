# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

config :sukhi_delivery, SukhiDelivery.Repo,
  database: "sukhi_fedi",
  username: "postgres",
  password: "postgres",
  hostname: "localhost"

config :sukhi_delivery, ecto_repos: [SukhiDelivery.Repo]

config :sukhi_delivery, Oban,
  repo: SukhiDelivery.Repo,
  # `push` is drained here and nowhere else: the gateway writes those jobs
  # (it makes the decision), this node sends them (it owns outbound HTTP).
  # Small concurrency — a doorbell is a few hundred bytes and there are
  # never many at once.
  queues: [delivery: 10, federation: 3, push: 3],
  plugins: [Oban.Plugins.Pruner]

# Web Push borrows the Finch pool this node already supervises for inbox
# POSTs, so nothing new is started for it.
config :web_push, finch: SukhiDelivery.Finch

config :sukhi_delivery, SukhiDelivery.PromEx,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled,
  metrics_server: :disabled

import_config "#{config_env()}.exs"
