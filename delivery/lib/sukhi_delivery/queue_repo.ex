# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.QueueRepo do
  @moduledoc """
  The PostgreSQL connection for the delivery node's job queues: Oban's
  `oban_jobs`, the same table the gateway's `SukhiFedi.QueueRepo` points at.

  The same database holds the gateway's `accounts` tables, read here through
  `SukhiDelivery.Accounts`, and its `outbox` table, which
  `SukhiDelivery.Outbox.Relay` reads. The rest of the business data is in
  hosigraph, which `SukhiDelivery.Repo` joins from the gateway.
  """

  use Ecto.Repo, otp_app: :sukhi_delivery, adapter: Ecto.Adapters.Postgres
end
