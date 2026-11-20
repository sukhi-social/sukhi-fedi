# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrate do
  @moduledoc """
  Brings the accounts' tables up to date at boot, from
  `priv/account_repo/migrations`. Returns `:ignore`, so it has finished before
  the next child starts (the same way as `SukhiFedi.Queue.Migrate`).

  The migrator takes a lock in the database, so two nodes booting together
  (the gateway and the delivery node) do not run it twice.
  """

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}

  def start_link do
    Ecto.Migrator.run(SukhiFedi.AccountRepo, :up, all: true, log: false)
    :ignore
  end
end
