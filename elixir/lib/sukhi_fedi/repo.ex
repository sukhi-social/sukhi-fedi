# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo do
  @moduledoc """
  The business data in hosigraph, through `ecto_hosi` (docs/STORE.md). Accounts,
  the audit trail and the outbox are not here (`SukhiFedi.AccountRepo`), nor are
  the job queues (`SukhiFedi.QueueRepo`): all of those are in PostgreSQL.
  """

  use Ecto.Repo,
    otp_app: :sukhi_fedi,
    adapter: SukhiFedi.Store.Adapter

  # A Multi of known changesets is one atomic write; anything else is run step
  # by step and undone on rollback (Ecto.Hosi.StaticMulti, Ecto.Hosi.Tx).
  use Ecto.Hosi.StaticMulti

  # What `use Ecto.Repo, adapter: Ecto.Adapters.Hosi` would add. The adapter is
  # reached through `SukhiFedi.Store.Adapter`, so ecto_hosi's own verbs are
  # delegated here.
  alias Ecto.Hosi.{Batch, RepoApi}

  @postgres_tables Enum.map(SukhiFedi.Store.Hosi.postgres(), & &1.__schema__(:source))

  @doc "A Datalog query against hosigraph (`Ecto.Hosi.Query.datalog/1`)."
  def datalog(query, opts \\ []), do: RepoApi.datalog(__MODULE__, query, opts)

  @doc "Every event of one entity."
  def history(id), do: RepoApi.history(__MODULE__, id)

  @doc "The newest `limit` rows by `field`: `{structs, last}`."
  def highest(schema, field, limit, opts \\ []),
    do: RepoApi.highest(__MODULE__, schema, field, limit, opts)

  @doc "The newest rows of some keys by a `hosi_tuple key, order` index: `[%{id, key, at}]`."
  def highest_in(schema, tuple, keys, limit, opts \\ []),
    do: RepoApi.highest_in(__MODULE__, schema, tuple, keys, limit, opts)

  @doc "Really remove entities (account removal), as hosigraph's `erase`."
  def erase(erasures), do: RepoApi.erase(__MODULE__, erasures)

  @doc "All-or-nothing writes of several rows in one hosigraph write."
  def write_batch(steps, opts \\ []), do: Batch.run(__MODULE__, steps, opts)

  # The store answers a query for a table it does not hold with no rows, so a
  # call meant for `SukhiFedi.AccountRepo` would pass for "not found". Every
  # query goes through here and is refused instead.
  @impl true
  def prepare_query(_operation, query, opts) do
    refuse_postgres!(query)
    {query, opts}
  end

  defp refuse_postgres!(%Ecto.Query{} = query) do
    Enum.each([query.from | query.joins], &refuse_source!/1)
    for %{subqueries: subqueries} <- query.wheres, sub <- subqueries, do: refuse_source!(sub)
  end

  defp refuse_source!(%Ecto.SubQuery{query: query}), do: refuse_postgres!(query)
  defp refuse_source!(%{source: %Ecto.SubQuery{} = sub}), do: refuse_source!(sub)

  defp refuse_source!(%{source: {table, _}}) when table in @postgres_tables do
    raise ArgumentError, "#{table} is a table of SukhiFedi.AccountRepo, not of the store"
  end

  defp refuse_source!(_), do: :ok

  # Where hosigraph keeps its files and how it reaches Datalevin, from the same
  # variables the Datalevin store read (DATALEVIN_DIR, DATALEVIN_BIN), in a
  # subdirectory of its own: the two do not share a format. `HOSI_JAR` (and
  # `HOSI_JAVA`) run Datalevin as a JVM with the standalone jar instead of the
  # native `dtlv`: for development and tests.
  @impl true
  def init(_type, config) do
    c = SukhiFedi.Store.Config.current()

    config =
      config
      |> Keyword.put_new(:dir, Path.join(c.dir, "ecto_hosi"))
      |> Keyword.put_new_lazy(:open, fn -> %{config: %{khana: khana(c)}} end)
      |> Keyword.put_new_lazy(:schemas, &SukhiFedi.Store.Hosi.schemas/0)

    {:ok, config}
  end

  defp khana(c) do
    case System.get_env("HOSI_JAR") do
      nil -> [:dtlv, c.bin]
      jar -> [:jvm, System.get_env("HOSI_JAVA", "java"), jar]
    end
  end
end
