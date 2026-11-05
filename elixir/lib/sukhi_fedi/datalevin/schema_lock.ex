# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.SchemaLock do
  @moduledoc """
  `priv/datalevin/schema.lock.json`: the Datalevin schema of both stores as
  the last release shipped it, and the newest migration it shipped with.

  The schema is derived (`priv/datalevin/catalog.exs` from the SQL
  migrations, `schema.edn` by hand), so changing it is a one-line diff that
  nobody reads as "this alters what is on disk". The lock makes it a
  reviewable diff of its own, and makes the one dangerous kind of change
  loud while the change is still a pull request:

    * the test (`check/2`) fails when the derived schema or the newest
      migration differs from the lock: run `mix sukhi.datalevin.lock`;
    * `mix sukhi.datalevin.lock` refuses to take a removed or changed
      attribute until a migration newer than the lock's exists
      (`update/2`): a new attribute needs nothing, anything else says
      what happens to the data (`SukhiFedi.Datalevin.Migration`).

  The file is one attribute per line, so the diff reads as the change.
  """

  alias SukhiFedi.Datalevin.{Catalog, Migrator, SchemaDiff, SchemaFile}

  @stores [:main, :graph]

  @type entry :: %{version: non_neg_integer(), schema: SchemaDiff.schema()}
  @type t :: %{main: entry(), graph: entry()}

  @doc "The lock as the code computes it now."
  @spec current(keyword()) :: t()
  def current(opts \\ []) do
    migrations = Keyword.get_lazy(opts, :migrations, &Migrator.discover/0)

    %{
      main: %{
        version: Migrator.latest_version(:main, migrations),
        schema: Catalog.dtlv_schema()
      },
      graph: %{
        version: Migrator.latest_version(:graph, migrations),
        schema: SchemaFile.to_dtlv(SchemaFile.read())
      }
    }
  end

  @doc "Where the file is, in the source tree (what the mix task writes)."
  @spec source_path() :: String.t()
  def source_path, do: Path.expand("../../../priv/datalevin/schema.lock.json", __DIR__)

  @spec read(String.t()) :: {:ok, t()} | {:error, String.t()}
  def read(path \\ source_path()) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = json} <- JSON.decode(body) do
      {:ok, Map.new(@stores, &{&1, entry(json[Atom.to_string(&1)])})}
    else
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
      _ -> {:error, "#{path} is not a lock file"}
    end
  end

  defp entry(%{"version" => v, "schema" => s}) when is_integer(v) and is_map(s),
    do: %{version: v, schema: s}

  defp entry(_), do: %{version: 0, schema: %{}}

  @doc "Problems that make the lock stale; `[]` when it matches."
  @spec check(t(), t()) :: [String.t()]
  def check(lock, current) do
    Enum.flat_map(@stores, fn store ->
      l = lock[store]
      c = current[store]
      diff = SchemaDiff.diff(l.schema, c.schema)

      [
        if(not SchemaDiff.empty?(diff),
          do: "#{store}: schema differs from the lock (#{SchemaDiff.describe(diff)})"
        ),
        if(l.version != c.version,
          do: "#{store}: newest migration is #{c.version}, the lock says #{l.version}"
        )
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  @doc """
  The lock to write for `current`, or the reasons it cannot be written yet
  (a removed or changed attribute with no migration newer than the lock's).
  """
  @spec update(t(), t()) :: {:ok, t()} | {:error, [String.t()]}
  def update(lock, current) do
    problems =
      Enum.flat_map(@stores, fn store ->
        diff = SchemaDiff.diff(lock[store].schema, current[store].schema)

        if SchemaDiff.additive?(diff) or current[store].version > lock[store].version,
          do: [],
          else: [
            "#{store}: #{SchemaDiff.describe(diff)}. The data under these attributes needs " <>
              "a migration: `mix sukhi.datalevin.gen.migration NAME --store #{store}`, " <>
              "then run this again."
          ]
      end)

    if problems == [], do: {:ok, current}, else: {:error, problems}
  end

  @doc "The file's text: one attribute per line, sorted."
  @spec encode(t()) :: String.t()
  def encode(lock) do
    body =
      Enum.map_join(@stores, ",\n", fn store ->
        %{version: v, schema: schema} = lock[store]

        attrs =
          schema
          |> Enum.sort()
          |> Enum.map_join(",\n", fn {attr, props} ->
            "    #{JSON.encode!(attr)}: #{props_json(props)}"
          end)

        ~s(  #{JSON.encode!(Atom.to_string(store))}: {\n    "version": #{v},\n    "schema": {\n) <>
          indent(attrs) <> "\n    }\n  }"
      end)

    "{\n" <> body <> "\n}\n"
  end

  defp indent(attrs), do: attrs |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  defp props_json(props) do
    "{" <>
      (props
       |> Enum.sort()
       |> Enum.map_join(", ", fn {k, v} -> JSON.encode!(k) <> ": " <> JSON.encode!(v) end)) <> "}"
  end
end
