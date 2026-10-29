# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo do
  use Ecto.Repo,
    otp_app: :sukhi_fedi,
    adapter: SukhiFedi.Store.Adapter

  # Oban picks its migrator from `repo.__adapter__()`, which is the dispatcher
  # here and not `Ecto.Adapters.Postgres`; say which one this repo needs.
  # (With `SUKHI_STORE=datalevin` Oban lives in `SukhiFedi.QueueRepo`.)
  @impl true
  def init(_type, config), do: {:ok, Keyword.put_new(config, :migrator, Oban.Migrations.Postgres)}
end
