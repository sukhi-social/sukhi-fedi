# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo do
  @moduledoc """
  The business data: hosigraph, through `ecto_hosi` (docs/STORE.md). Job queues
  are not here; they are in PostgreSQL (`SukhiFedi.QueueRepo`).
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
