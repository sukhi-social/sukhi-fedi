# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Store.Hosi do
  @moduledoc """
  What `SukhiFedi.Repo` hands to `Ecto.Adapters.Hosi` (docs/STORE.md).

  `ecto_hosi` derives the hosigraph schema from Ecto schemas, so it needs the
  list of them. That list is every `SukhiFedi.Schema.*` module that is an Ecto
  schema, found from the application's module list: a new schema file joins
  the store without anyone remembering to register it. The ones named in
  `@postgres` are `SukhiFedi.AccountRepo`'s tables and stay out;
  `SukhiFedi.Repo` refuses a query for one.
  """

  @postgres Enum.map(
              ~w(Account AccountDeletion AdminAudit EmailCode InviteCode InviteCodeUse JoinApplication
                 OauthAccessToken OauthApp OauthAuthorizationCode OutboxEvent Session
                 WebauthnChallenge WebauthnCredential),
              &Module.concat(SukhiFedi.Schema, &1)
            )

  @doc "The schemas whose tables are in PostgreSQL."
  @spec postgres() :: [module()]
  def postgres, do: @postgres

  @doc "The Ecto schema modules under `SukhiFedi.Schema` that the store holds, sorted."
  @spec schemas() :: [module()]
  def schemas do
    Application.load(:sukhi_fedi)
    {:ok, modules} = :application.get_key(:sukhi_fedi, :modules)

    modules
    |> Enum.filter(&(schema?(&1) and &1 not in @postgres))
    |> Enum.sort()
  end

  @doc """
  Remove every row of every schema, really (`Repo.erase/1`). For tests: the
  hosi store has no sandbox, so each test starts from an empty database.
  """
  @spec wipe!() :: :ok
  def wipe! do
    import Ecto.Query, only: [from: 2]

    for schema <- schemas(),
        ids = SukhiFedi.Repo.all(from(s in schema, select: s.id)),
        ids != [] do
      SukhiFedi.Repo.erase([[:ids, ids]])
    end

    :ok
  end

  defp schema?(mod) do
    match?(["SukhiFedi", "Schema" | _], Module.split(mod)) and
      Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1) and
      mod.__schema__(:source) != nil
  end
end
