# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.QueueRepo do
  @moduledoc """
  The PostgreSQL connection for the delivery node's job queues: Oban's
  `oban_jobs`, the same table the gateway's `SukhiFedi.QueueRepo` points at.

  This is all PostgreSQL is for. The business data is in Datalevin, which
  `SukhiDelivery.Repo` joins from the gateway; see `SukhiDelivery.Queue`.
  """

  use Ecto.Repo, otp_app: :sukhi_delivery, adapter: Ecto.Adapters.Postgres
end
