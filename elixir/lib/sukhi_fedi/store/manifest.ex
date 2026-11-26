# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Store.Manifest do
  @moduledoc """
  The restore inventory a backup carries (`backup-manifest.json`) and its check.

  The store is hosigraph (docs/STORE.md); it derives its schema from the Ecto schemas when it
  opens, so there is no migration state to record. The inventory says where the data lives and
  which raw backend applied, and `validate_backup!/3` refuses a restore whose paths or raw
  backend do not match the runtime it is restored into.

  `<dir>/.sukhi-store.json` is the file the old Datalevin store kept beside its data. A store
  that still has one carries it into a backup; nothing writes it any more.
  """

  alias SukhiFedi.Store.Config
  require Logger

  @inventory_format 1
  @manifest_file ".sukhi-store.json"

  @spec path(Config.t()) :: String.t()
  def path(%Config{dir: dir}), do: Path.join(dir, @manifest_file)

  @doc "The file name, for callers that must tell it apart from data."
  @spec file_name() :: String.t()
  def file_name, do: @manifest_file

  @doc "The format of the backup inventory."
  @spec inventory_format() :: pos_integer()
  def inventory_format, do: @inventory_format

  @doc """
  Validate a backup inventory (`Release.write_backup_manifest!/1`) against this runtime: the
  data directory and the raw backend must match.
  """
  @spec validate_backup!(String.t(), Config.t(), map()) :: :ok
  def validate_backup!(file, %Config{} = config, env \\ System.get_env()) do
    with {:ok, body} <- File.read(file),
         {:ok, manifest} <- JSON.decode(body),
         :ok <- validate_shape(manifest),
         :ok <- validate_path(manifest["data_dir"], config.dir, "data directory"),
         :ok <-
           validate_value(
             manifest["raw_backend"],
             Map.get(env, "SUKHI_RAW_BACKEND", "postgres"),
             "raw backend"
           ) do
      Logger.info("backup_manifest_valid path=#{file}")
      :ok
    else
      {:error, reason} -> refuse!("backup manifest invalid #{file}: #{reason}")
      :error -> refuse!("backup manifest invalid #{file}")
    end
  end

  defp validate_shape(%{"format" => @inventory_format, "store" => store})
       when store in ["hosi", "datalevin"],
       do: :ok

  defp validate_shape(manifest) when is_map(manifest), do: {:error, "store or format does not match"}
  defp validate_shape(_), do: {:error, "manifest is not an object"}

  defp validate_path(actual, expected, _label) when actual == expected, do: :ok
  defp validate_path(_, _, label), do: {:error, "#{label} path does not match current runtime"}

  defp validate_value(actual, expected, _label) when actual == expected, do: :ok
  defp validate_value(_, _, label), do: {:error, "#{label} does not match current runtime"}

  defp refuse!(message), do: raise(ArgumentError, message)
end
