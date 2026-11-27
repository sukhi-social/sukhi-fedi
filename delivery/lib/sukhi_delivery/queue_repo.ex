# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.QueueRepo do
  @moduledoc """
  The PostgreSQL connection for the delivery node's job queues: Oban's
  `oban_jobs`, the same table the gateway's `SukhiFedi.QueueRepo` points at.

  The same database holds the `outbox` table, which the gateway writes and
  `SukhiDelivery.Outbox.Relay` reads here. Most business data is in
  hosigraph, which `SukhiDelivery.Repo` joins from the gateway.
  """

  use Ecto.Repo, otp_app: :sukhi_delivery, adapter: Ecto.Adapters.Postgres
end
