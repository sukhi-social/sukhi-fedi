# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# The queue database, the same one the gateway's tests use (docs/TESTING.md):
# env-overridable (the docker-compose Postgres by default, pgrust under
# `make test-pgrust`).
config :sukhi_delivery, SukhiDelivery.QueueRepo,
  database: System.get_env("DB_NAME", "sukhi_fedi_test"),
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("DB_PORT", "15432")),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "5"))

config :sukhi_delivery, Oban, testing: :inline

# The worker test delivers to an http://localhost Bypass server, which the
# SSRF guard rejects in dev/prod. Disable it under test only.
config :sukhi_shared, :disable_url_guard, true
