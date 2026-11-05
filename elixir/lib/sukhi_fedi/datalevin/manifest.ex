# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Manifest do
  @moduledoc """
  Records the application/catalog identity of a Datalevin store.

  A store copied from an older release without a manifest is accepted once and
  stamped after it opens. A manifest with a different catalog fingerprint is
  refused before the application can serve requests.
  """

  alias SukhiFedi.Datalevin.{Catalog, Config}
  require Logger

  @format 1
  @manifest_file ".sukhi-store.json"

  @spec path(Config.t()) :: String.t()
  def path(%Config{dir: dir}), do: Path.join(dir, @manifest_file)

  @spec expected(Config.t()) :: map()
  def expected(%Config{} = config) do
    %{
      "format" => @format,
      "store" => "datalevin",
      "catalog_sha256" => catalog_sha256(),
      "app_version" => app_version(),
      "data_dir" => config.dir
    }
  end

  @spec verify!(Config.t()) :: :ok | :legacy
  def verify!(%Config{} = config) do
    file = path(config)

    case File.read(file) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, manifest} -> verify!(manifest, expected(config), file)
          {:error, reason} -> refuse!("invalid store manifest #{file}: #{inspect(reason)}")
        end

      {:error, :enoent} ->
        Logger.warning("datalevin store manifest missing; accepting legacy store #{config.dir}")
        :legacy

      {:error, reason} ->
        refuse!("cannot read store manifest #{file}: #{inspect(reason)}")
    end
  end

  @spec write!(Config.t()) :: :ok
  def write!(%Config{} = config) do
    file = path(config)
    body = JSON.encode!(expected(config))
    :ok = File.write(file, body <> "\n")
    :ok
  end

  @doc "Validate a previously generated backup inventory against this runtime."
  @spec validate_backup!(String.t(), Config.t(), map()) :: :ok
  def validate_backup!(file, %Config{} = config, env \\ System.get_env()) do
    with {:ok, body} <- File.read(file),
         {:ok, manifest} <- JSON.decode(body),
         :ok <- validate_backup_shape(manifest, config),
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

  defp verify!(manifest, expected, file) do
    if manifest["format"] != expected["format"] or
         manifest["catalog_sha256"] != expected["catalog_sha256"] do
      refuse!(
        "datalevin store is incompatible: #{file}; " <>
          "stored catalog=#{inspect(manifest["catalog_sha256"])} " <>
          "current catalog=#{expected["catalog_sha256"]}; " <>
          "use the matching image/catalog or restore a compatible backup"
      )
    end

    :ok
  end

  defp validate_backup_shape(manifest, config) when is_map(manifest) do
    if manifest["store"] == "datalevin" and
         manifest["format"] == @format and
         manifest["catalog_sha256"] == expected(config)["catalog_sha256"] do
      :ok
    else
      {:error, "store, format, or catalog fingerprint does not match"}
    end
  end

  defp validate_backup_shape(_, _), do: {:error, "manifest is not an object"}

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

  defp catalog_sha256 do
    Catalog.dtlv_schema()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp app_version do
    case Application.spec(:sukhi_fedi, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end
end
