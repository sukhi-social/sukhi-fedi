# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Repo do
  @moduledoc """
  The business data this node reads and writes: the gateway's hosigraph store,
  joined through `SukhiDelivery.Store.Adapter`. Accounts, the outbox and the
  job queues are not here; they are in PostgreSQL (`SukhiDelivery.QueueRepo`).
  """

  use Ecto.Repo,
    otp_app: :sukhi_delivery,
    adapter: SukhiDelivery.Store.Adapter

  # The store is the gateway's: share its connection and rules instead of opening another.
  @impl true
  def init(_type, config), do: {:ok, Keyword.put(config, :join, SukhiFedi.Repo)}
end
