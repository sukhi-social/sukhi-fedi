# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Repo do
  use Ecto.Repo,
    otp_app: :sukhi_delivery,
    adapter: SukhiDelivery.Store.Adapter

  # Oban picks its migrator from `repo.__adapter__()`, which is the dispatcher
  # here and not `Ecto.Adapters.Postgres`; say which one this repo needs.
  @impl true
  def init(_type, config), do: {:ok, Keyword.put_new(config, :migrator, Oban.Migrations.Postgres)}

  @doc "Does this node keep its business data in Datalevin (`SUKHI_STORE=datalevin`)?"
  @spec datalevin?() :: boolean()
  def datalevin?, do: __adapter__().kind() == :datalevin
end
