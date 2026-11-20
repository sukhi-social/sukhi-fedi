# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# Same env-overridable connection as the gateway's dev config — the two
# queue repos share one database, and `make dev` points both at pgrust.
config :sukhi_delivery, SukhiDelivery.QueueRepo,
  database: "sukhi_fedi_dev",
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10"))

# NATS is at its default 127.0.0.1:4222 unless told otherwise, but
# `make dev` starts nats-server on its own port so it never collides
# with a docker-compose stack. Same env names as config/test.exs and
# the prod block in runtime.exs.
config :sukhi_delivery, :nats,
  host: System.get_env("NATS_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("NATS_PORT", "4222"))
