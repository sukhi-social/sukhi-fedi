# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# Connection is env-overridable so the same dev setup runs against a
# docker-compose Postgres (the defaults) or against PGlite — Postgres
# compiled to WASM, no Docker daemon needed. `make dev` takes the PGlite
# path; see scripts/dev.sh.
config :sukhi_fedi, SukhiFedi.Repo,
  database: "sukhi_fedi_dev",
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  # The same two bends config/test.exs makes for PGlite, and for the
  # same reasons (see docs/TESTING.md): its socket multiplexer mishandles
  # *named* prepared statements, and the migration lock takes a second
  # connection that deadlocks against the migrating one. Both are
  # harmless against a real Postgres — a single dev migrator never races.
  prepare: :unnamed,
  migration_lock: false

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

# PGlite is one Postgres that its socket server multiplexes client
# connections onto, and that multiplexing breaks Postgrex — a write
# lands as `no function clause matching in
# Postgrex.Protocol.handle_msg/3` on `{:msg_command_complete, "BEGIN"}`.
# scripts/dev.sh keeps the pool at 1 for that reason, but Oban still
# opens a *second* connection of its own outside the pool
# (`Oban.Peers.Database` over `Postgrex.SimpleConnection`, for leader
# election), and that one breaks the same way.
#
# So on the PGlite path Oban runs the way config/test.exs runs it:
# jobs execute inline at insert, no queues, no plugins, no notifier.
# Point DB_PORT at a real Postgres and drop PGLITE to get them back.
if System.get_env("PGLITE") == "1" do
  config :sukhi_fedi, Oban, testing: :inline
end
