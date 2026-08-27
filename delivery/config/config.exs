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
  # `outbox_dispatch` drains the outbox: one job per row, each fanning
  # out into `delivery` jobs. Low concurrency — a few events a day, and
  # each one only translates and enqueues.
  queues: [delivery: 10, federation: 3, push: 3, outbox_dispatch: 2],
  # `discarded` is the dead-letter shelf (see Outbox.DispatchWorker), so
  # the Pruner must not sweep it — without the `:states` override its
  # 60-second default would delete a dead-lettered activity a minute
  # after it gave up, which is the failure the OUTBOX_DLQ stream used to
  # cover. Completed and cancelled jobs still age out as before.
  #
  # Lifeline is what makes a hard crash lossless. Oban never rescues an
  # `executing` job on its own: if the BEAM dies by SIGKILL or OOM
  # mid-job, that row sits in `executing` forever and nothing runs it
  # again. JetStream used to cover this with its 30 s ack-wait
  # redelivery, so without Lifeline moving the outbox onto Oban would
  # have traded a lossless window for a lossy one.
  #
  # `rescue_after` has to clear the longest a job can legitimately run,
  # because rescuing is purely time-based and will re-run a job that is
  # genuinely still working. The slowest single step is a 30 s inbox
  # POST (`Delivery.Worker`) or a 10 s translate plus one 10 s actor
  # fetch per uncached recipient (`Outbox.DispatchWorker`); 15 minutes
  # is ~90 serial fetches, well past anything real. A double run is safe
  # either way — `delivery_receipts` makes the POST idempotent and a
  # re-dispatched event just re-enqueues jobs that same table absorbs.
  plugins: [
    {Oban.Plugins.Pruner, states: [:completed, :cancelled]},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(15)}
  ]

# Web Push borrows the Finch pool this node already supervises for inbox
# POSTs, so nothing new is started for it.
config :web_push, finch: SukhiDelivery.Finch

config :sukhi_delivery, SukhiDelivery.PromEx,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled,
  metrics_server: :disabled

import_config "#{config_env()}.exs"
