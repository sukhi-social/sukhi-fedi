# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.QueueRepo do
  @moduledoc """
  Single-node SQLite file holding the delivery job queues when
  `DELIVERY_QUEUE=sqlite`. Business data stays in `SukhiDelivery.Repo`;
  see `SukhiDelivery.Queue`.
  """

  use Ecto.Repo, otp_app: :sukhi_delivery, adapter: Ecto.Adapters.SQLite3
end
