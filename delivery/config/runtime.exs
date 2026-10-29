# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# Public-facing domain used to mint activity ids, actor URIs, and
# HTTP-Signature keyIds on outbound deliveries. Must match the
# gateway's DOMAIN — otherwise keyId dereference on the receiving
# server fails and every POST comes back 401. Prod requires it via
# fetch_env! so the release dies at boot on a missing/mismatched env.
if config_env() == :prod do
  config :sukhi_delivery, :domain, System.fetch_env!("DOMAIN")
else
  config :sukhi_delivery, :domain, System.get_env("DOMAIN", "localhost:4000")
end

if config_env() == :prod do
  config :sukhi_delivery, SukhiDelivery.Repo,
    database: System.get_env("DB_NAME", "sukhi_fedi"),
    username: System.fetch_env!("DB_USER"),
    password: System.fetch_env!("DB_PASS"),
    hostname: System.get_env("DB_HOST", "localhost"),
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "5"))

  config :sukhi_delivery, :nats,
    host: System.get_env("NATS_HOST", "127.0.0.1"),
    port: String.to_integer(System.get_env("NATS_PORT", "4222"))

  config :sukhi_delivery, :metrics_port,
    String.to_integer(System.get_env("METRICS_PORT", "4001"))

  # Per-queue Oban concurrency overrides. On a 1 GB free-tier box the
  # compile-time defaults (delivery: 10, federation: 3) keep too many
  # Finch sockets and inflight HTTP bodies in BEAM heap at once.
  # Config.config/3 shallow-merges keyword lists, so overriding just
  # `:queues` leaves `:repo` and `:plugins` from compile-time intact.
  # The list itself, though, is replaced wholesale — a queue missing from
  # here simply never drains in prod, quietly. Name every one.
  config :sukhi_delivery, Oban,
    queues: [
      delivery: String.to_integer(System.get_env("OBAN_DELIVERY_CONCURRENCY", "10")),
      federation: String.to_integer(System.get_env("OBAN_FEDERATION_CONCURRENCY", "3")),
      push: String.to_integer(System.get_env("OBAN_PUSH_CONCURRENCY", "3")),
      outbox_dispatch:
        String.to_integer(System.get_env("OBAN_OUTBOX_DISPATCH_CONCURRENCY", "2"))
    ]

  # Delivery queue backend. `sqlite` moves the `delivery` and
  # `outbox_dispatch` queues to a single-node SQLite file (Oban Lite); the
  # rest stays in Postgres. Single node only — the file is not shared.
  if System.get_env("DELIVERY_QUEUE", "postgres") == "sqlite" do
    config :sukhi_delivery, :queue_backend, :sqlite

    # Combined release only (one BEAM): lets the gateway enqueue its delivery sends
    # into the SQLite queue and read it for delivery status / discarded count. Harmless on a lone
    # delivery node, where :sukhi_fedi isn't running.
    config :sukhi_fedi, :extra_job_repos, [SukhiDelivery.QueueRepo]
    config :sukhi_fedi, :delivery_oban, SukhiDelivery.QueueOban

    config :sukhi_delivery, SukhiDelivery.QueueRepo,
      database: System.get_env("DELIVERY_QUEUE_DB", "/var/lib/sukhi/delivery_queue.db"),
      journal_mode: :wal,
      synchronous: String.to_atom(System.get_env("DELIVERY_QUEUE_SYNCHRONOUS", "full")),
      pool_size: String.to_integer(System.get_env("DELIVERY_QUEUE_POOL_SIZE", "5"))

    config :sukhi_delivery,
           :queue_retention_seconds,
           String.to_integer(System.get_env("DELIVERY_QUEUE_RETENTION_SECONDS", "2592000"))
  end

  # Outbound HTTP pool sizing. Consumed by SukhiDelivery.Application.
  config :sukhi_delivery, :finch_pool,
    size: String.to_integer(System.get_env("FINCH_POOL_SIZE", "50")),
    count: String.to_integer(System.get_env("FINCH_POOL_COUNT", "4"))

  # ── Web Push (VAPID) ───────────────────────────────────────────────────
  # The same keypair the gateway hands to clients; this node signs with it.
  # Without one push is simply off — the gateway never enqueues, so nothing
  # here ever runs.
  vapid_public = System.get_env("VAPID_PUBLIC_KEY")

  if vapid_public not in [nil, ""] do
    config :web_push, :vapid,
      public_key: vapid_public,
      private_key: System.fetch_env!("VAPID_PRIVATE_KEY"),
      subject:
        System.get_env(
          "VAPID_SUBJECT",
          "mailto:admin@" <> System.get_env("DOMAIN", "localhost")
        )
  end
end

# Must agree with the gateway: both read PULL_FEDERATION. Off ⇒ every
# follower is pushed to and actors omit the FEP-844e `generator`.
config :sukhi_shared, :pull_federation, System.get_env("PULL_FEDERATION", "on") != "off"
