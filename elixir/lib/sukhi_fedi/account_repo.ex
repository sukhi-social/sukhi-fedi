# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo do
  @moduledoc """
  The PostgreSQL connection for accounts and how they sign in: `accounts`,
  `sessions`, the OAuth tables, passkeys, email codes, invite codes and join
  applications. The keys an account signs with and its settings are columns of
  its `accounts` row.

  Its tables are in `priv/account_repo/migrations`, run at boot by
  `SukhiFedi.AccountRepo.Migrate`. The rest of the business data is Datalevin
  (`SukhiFedi.Repo`); the two stores share no transaction and no foreign key,
  so a row there that names an account is checked by the code that writes it.
  """

  use Ecto.Repo, otp_app: :sukhi_fedi, adapter: Ecto.Adapters.Postgres
end
