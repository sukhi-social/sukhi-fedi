# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# The bundled legal wording the tests serve. Production names its set
# explicitly (LEGAL_FLAVOR); there is no default there.
config :sukhi_fedi, :legal_flavor, :sukhi

# The queue database (PostgreSQL) is env-overridable so the same test suite
# runs against the docker-compose Postgres (default) or the pgrust server
# `make test-pgrust` starts (no Docker). The defaults (postgres/postgres) match
# both. The accounts (`AccountRepo`) and the queue (`QueueRepo`) share it; the
# rest of the business data is Datalevin and needs no connection here.
db = [
  database: System.get_env("DB_NAME", "sukhi_fedi_test"),
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("DB_PORT", "15432")),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10"))
]

config :sukhi_fedi, SukhiFedi.QueueRepo, db
config :sukhi_fedi, SukhiFedi.AccountRepo, db

# Tests start each case from an empty store; an answer kept in memory would not.
config :sukhi_fedi, :hot_cache, false

# FEP-f799 keeps its notices in PostgreSQL; the unit tests run without a
# database. The tests of that feature (`:integration`, under
# test/sukhi_fedi/fedi/delivery_suspension) call the Receiver and the Store
# themselves.
config :sukhi_fedi, :delivery_suspension, false

config :sukhi_fedi, Oban, testing: :inline

# Link-preview generation fetches arbitrary URLs over the network; keep it
# off in tests so note creation stays hermetic. Exercised directly in
# `SukhiFedi.PreviewCardsTest` instead.
config :sukhi_fedi, link_previews: false

# boot 時の backfill pending は sandbox の外から DB を触るので、テストでは
# 走らせない（`Federation.OutboxBackfillTest` が選別だけを見る）。
config :sukhi_fedi, backfill_on_boot: false

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

# The Pull Federation scheduler polls the database on a timer; the tests
# that exercise pulls call `Pull.run/1` directly instead.
config :sukhi_fedi, :pull_federation, tick_ms: nil
