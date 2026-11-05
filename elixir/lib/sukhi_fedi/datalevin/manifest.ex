# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Manifest do
  @moduledoc """
  The record a Datalevin store keeps of itself: `<dir>/.sukhi-store.json`.
  The main store and the graph store (`<dir>/graph`) each have one.

  Format 2 says which migrations the data has been through and what schema
  the store was last opened with, so the next release can tell what changed
  (`SchemaDiff`) instead of refusing every difference:

      "format"         2
      "name"           "main" | "graph"
      "schema_version" the newest applied migration (0: none)
      "migrations"     [{"version", "name", "applied_at"}]
      "schema"         the schema it was last stamped with (wire form)
      "migrating"      null, or {"version", "started_at"} while one runs
      "catalog_sha256" a fingerprint of "schema" (for the backup inventory)

  Format 1 (the catalog fingerprint alone) is read once and upgraded by the
  migrator. The file lives beside the data, so a backup of the directory
  carries it; it is written by rename, so it is never half a file.

  This module only reads and writes the file and checks a backup inventory;
  what the contents mean is `SukhiFedi.Datalevin.Migrator`'s.
  """

  alias SukhiFedi.Datalevin.{Config, Migrator}
  require Logger

  @format 2
  @inventory_format 1
  @manifest_file ".sukhi-store.json"

  @type t :: %{String.t() => term()}

  @spec path(Config.t()) :: String.t()
  def path(%Config{dir: dir}), do: Path.join(dir, @manifest_file)

  @doc "The file name, for callers that must tell it apart from data."
  @spec file_name() :: String.t()
  def file_name, do: @manifest_file

  @spec read(Config.t()) :: {:ok, t()} | :none | {:error, String.t()}
  def read(%Config{} = config) do
    file = path(config)

    case File.read(file) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{} = manifest} -> {:ok, manifest}
          {:ok, _} -> {:error, "invalid store manifest #{file}: not an object"}
          {:error, reason} -> {:error, "invalid store manifest #{file}: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, "cannot read store manifest #{file}: #{inspect(reason)}"}
    end
  end

  @doc "A format-2 manifest."
  @spec build(Config.t(), :main | :graph, Migrator.schema(), [map()], map() | nil) :: t()
  def build(%Config{} = config, name, schema, applied, migrating \\ nil) do
    %{
      "format" => @format,
      "store" => "datalevin",
      "name" => Atom.to_string(name),
      "schema_version" => applied |> Enum.map(& &1["version"]) |> Enum.max(fn -> 0 end),
      "migrations" => applied,
      "migrating" => migrating,
      "schema" => schema,
      "catalog_sha256" => schema_sha256(schema),
      "app_version" => app_version(),
      "data_dir" => config.dir
    }
  end

  @doc "Write by rename, so a crash leaves the old file or the new one."
  @spec write!(Config.t(), t()) :: :ok
  def write!(%Config{} = config, manifest) do
    file = path(config)
    tmp = file <> ".tmp"
    File.mkdir_p!(config.dir)
    File.write!(tmp, JSON.encode!(manifest) <> "\n")
    File.rename!(tmp, file)
    :ok
  end

  @doc "A fingerprint of a schema that does not depend on map order or the OTP version."
  @spec schema_sha256(Migrator.schema()) :: String.t()
  def schema_sha256(schema) do
    schema
    |> Enum.sort()
    |> Enum.map(fn {attr, props} -> [attr, Enum.sort(props)] end)
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The fingerprint format 1 stored (`term_to_binary` of the schema): enough to
  recognise a store stamped by the release before migrations existed.
  """
  @spec legacy_sha256(Migrator.schema()) :: String.t()
  def legacy_sha256(schema) do
    schema
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Validate a backup inventory (`Release.write_datalevin_backup_manifest!/1`)
  against this runtime: the paths and the raw backend must match, and the
  data must be a version this release can bring forward. An inventory from
  before migrations (no `"schema_version"`) must carry this catalog's
  fingerprint, as it always had to.
  """
  @spec validate_backup!(String.t(), Config.t(), map()) :: :ok
  def validate_backup!(file, %Config{} = config, env \\ System.get_env()) do
    with {:ok, body} <- File.read(file),
         {:ok, manifest} <- JSON.decode(body),
         :ok <- validate_backup_shape(manifest),
         :ok <- validate_version(manifest),
         :ok <- validate_path(manifest["data_dir"], config.dir, "data directory"),
         :ok <- validate_path(manifest["data_dir_manifest"], path(config), "store manifest"),
         :ok <-
           validate_value(
             manifest["raw_backend"],
             Map.get(env, "SUKHI_RAW_BACKEND", "sqlite"),
             "raw backend"
           ),
         :ok <- validate_existing(manifest["queue_db"], "queue database"),
         :ok <- validate_existing(manifest["delivery_queue_db"], "delivery queue database"),
         :ok <- validate_graph(manifest, config, env) do
      Logger.info("datalevin_backup_manifest_valid path=#{file}")
      :ok
    else
      {:error, reason} -> refuse!("datalevin backup manifest invalid #{file}: #{reason}")
      :error -> refuse!("datalevin backup manifest invalid #{file}")
    end
  end

  @doc "The format of the backup inventory (not of the store manifest)."
  @spec inventory_format() :: pos_integer()
  def inventory_format, do: @inventory_format

  defp validate_backup_shape(manifest) when is_map(manifest) do
    if manifest["store"] == "datalevin" and manifest["format"] == @inventory_format,
      do: :ok,
      else: {:error, "store or format does not match"}
  end

  defp validate_backup_shape(_), do: {:error, "manifest is not an object"}

  # Newer data than this release knows cannot be read back; older data is
  # migrated forward when the release starts.
  defp validate_version(%{"schema_version" => v}) when is_integer(v) do
    latest = Migrator.latest_version(:main)

    if v <= latest,
      do: :ok,
      else:
        {:error,
         "the backup holds schema version #{v}, newer than this release knows (#{latest}); " <>
           "start the release that wrote it"}
  end

  defp validate_version(manifest) do
    expected = legacy_sha256(SukhiFedi.Datalevin.Catalog.dtlv_schema())

    if manifest["catalog_sha256"] == expected,
      do: :ok,
      else: {:error, "catalog fingerprint does not match"}
  end

  defp validate_path(actual, expected, _label) when actual == expected, do: :ok
  defp validate_path(_, _, label), do: {:error, "#{label} path does not match current runtime"}

  defp validate_value(actual, expected, _label) when actual == expected, do: :ok
  defp validate_value(_, _, label), do: {:error, "#{label} does not match current runtime"}

  defp validate_existing(path, label) when is_binary(path) do
    if File.exists?(path), do: :ok, else: {:error, "#{label} is missing: #{path}"}
  end

  defp validate_existing(_, label), do: {:error, "#{label} path is missing"}

  defp validate_graph(manifest, config, env) do
    if Map.get(env, "SUKHI_GRAPH", "0") in ["1", "true"] do
      validate_path(manifest["graph_dir"], Path.join(config.dir, "graph"), "graph directory")
      |> case do
        :ok -> validate_existing(manifest["graph_dir"], "graph directory")
        error -> error
      end
    else
      :ok
    end
  end

  defp refuse!(message), do: raise(ArgumentError, message)

  defp app_version do
    case Application.spec(:sukhi_fedi, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end
end
