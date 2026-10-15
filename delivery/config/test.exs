# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

config :sukhi_delivery, SukhiDelivery.Repo,
  database: "sukhi_fedi_test",
  port: String.to_integer(System.get_env("DB_PORT", "15432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :sukhi_delivery, Oban, testing: :inline

# The worker test delivers to an http://localhost Bypass server, which the
# SSRF guard rejects in dev/prod. Disable it under test only.
config :sukhi_shared, :disable_url_guard, true
