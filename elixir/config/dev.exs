# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# The queue database's connection is env-overridable so the same dev setup
# runs against a docker-compose Postgres (the defaults) or against the pgrust
# server `make dev` starts (no Docker daemon needed; see scripts/dev.sh).
# (The accounts, `AccountRepo`, and the queue, `QueueRepo`, share it; the rest
# of the business data is Datalevin.)
db = [
  database: "sukhi_fedi_dev",
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10"))
]

config :sukhi_fedi, SukhiFedi.QueueRepo, db
config :sukhi_fedi, SukhiFedi.AccountRepo, db

# Stable dev value so the admin session cookie keeps working across
# `iex -S mix` restarts. NEVER use this in prod — prod reads from
# the SECRET_KEY_BASE env var (see runtime.exs).
config :sukhi_fedi, :secret_key_base,
  "dev_only_key_NOT_FOR_PRODUCTION_use_openssl_rand_hex_64_in_prod_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Dev runs over plain HTTP (no kamal-proxy TLS), so the secure cookie
# flag would prevent the session from being set at all.
config :sukhi_fedi, :admin_session_secure, false

# NATS is at its default 127.0.0.1:4222 unless told otherwise, but
# `make dev` starts nats-server on its own port so it never collides
# with a docker-compose stack. Same env names as config/test.exs and
# the prod block in runtime.exs.
config :sukhi_fedi, :nats,
  host: System.get_env("NATS_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("NATS_PORT", "4222"))
