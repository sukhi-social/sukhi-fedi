# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# Connection is env-overridable so the same test suite runs against the
# docker-compose Postgres (default) or the PGlite embedded DB (no Docker;
# `make test-pglite` / `bun run services/test_db.ts`). PGlite serves a
# single connection multiplexed, so the pglite path sets DB_POOL_SIZE=1.
# Defaults (postgres/postgres) match both the docker image and PGlite.
config :sukhi_fedi, SukhiFedi.Repo,
  database: System.get_env("DB_NAME", "sukhi_fedi_test"),
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("DB_PORT", "15432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  # PGlite's socket multiplexer mishandles *named* prepared statements
  # (reused plan + different param count → 08P01 protocol_violation), so
  # use unnamed prepares. Harmless on real Postgres, just marginally
  # slower — fine for the test path.
  prepare: :unnamed,
  # The migration lock takes a second connection and holds it for the
  # whole run; on PGlite's multiplexer that deadlocks against the
  # migrating connection. A single test migrator never races, so the
  # lock is unnecessary here.
  migration_lock: false

config :sukhi_fedi, Oban, testing: :inline

# Link-preview generation fetches arbitrary URLs over the network; keep it
# off in tests so note creation stays hermetic. Exercised directly in
# `SukhiFedi.PreviewCardsTest` instead.
config :sukhi_fedi, link_previews: false

# Don't auto-sample host metrics in tests — the Sampler would write to the
# Repo outside any test's sandbox checkout. `nil` makes it start as :ignore;
# `SukhiFedi.Metrics.record/0` is still exercised directly in metrics_test.
config :sukhi_fedi, :metrics, sample_interval_ms: nil

config :sukhi_fedi, :nats,
  host: System.get_env("NATS_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("NATS_PORT", "14222"))

# Deterministic admin-session signing key for tests.
config :sukhi_fedi,
       :secret_key_base,
       "test_key_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Mails land in an ETS table tests can read (Mailer.Capture.all/0)
# instead of going anywhere near a socket.
config :sukhi_fedi, :mailer,
  transport: SukhiFedi.Mailer.Capture,
  from: "test@localhost"

# Every test conn shares 127.0.0.1, so the per-IP mail gate would trip
# across unrelated tests. The per-address limits stay exercised.
config :sukhi_fedi, :mail_ip_limit, 1_000_000

# Point ex_aws at the rustfs container from docker-compose.test.yml.
config :ex_aws, :s3,
  scheme: "http://",
  host: System.get_env("S3_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("S3_PORT", "19000")),
  region: "us-east-1"

config :ex_aws,
  access_key_id: "testaccess",
  secret_access_key: "testsecret",
  json_codec: Jason

config :sukhi_fedi, :s3,
  bucket: "media-test",
  inbound_bucket: "inbound-test",
  outbound_bucket: "outbound-test",
  enabled: true
