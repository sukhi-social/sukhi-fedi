# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# Same env-overridable connection as the gateway's dev config — the two
# repos share one database, and `make dev` points both at PGlite.
config :sukhi_delivery, SukhiDelivery.Repo,
  database: "sukhi_fedi_dev",
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  # PGlite mishandles named prepares; harmless on real Postgres. Delivery
  # never migrates, so it needs no migration_lock bend.
  prepare: :unnamed

# NATS is at its default 127.0.0.1:4222 unless told otherwise, but
# `make dev` starts nats-server on its own port so it never collides
# with a docker-compose stack. Same env names as config/test.exs and
# the prod block in runtime.exs.
config :sukhi_delivery, :nats,
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
  config :sukhi_delivery, Oban, testing: :inline
end
