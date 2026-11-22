# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RawStore.Postgres do
  @moduledoc """
  Blobs in a `raw_blobs` table of the queue database (`SukhiFedi.QueueRepo`
  by default): no new service to run. `ensure_table/1` is idempotent and is
  called at boot by `SukhiFedi.Queue.Migrate`.
  """

  @behaviour SukhiFedi.RawStore.Backend

  @default_repo SukhiFedi.QueueRepo

  @spec ensure_table(module()) :: :ok
  def ensure_table(repo \\ @default_repo) do
    repo.query!("""
    CREATE TABLE IF NOT EXISTS raw_blobs (
      ref text PRIMARY KEY,
      body bytea NOT NULL,
      size bigint NOT NULL,
      created_at bigint NOT NULL
    )
    """)

    :ok
  end

  @impl true
  def put(key, body, opts) do
    repo(opts).query!(
      "INSERT INTO raw_blobs (ref, body, size, created_at) VALUES ($1, $2, $3, $4) ON CONFLICT (ref) DO NOTHING",
      [key, body, byte_size(body), System.os_time(:second)]
    )

    :ok
  rescue
    e -> {:error, e}
  end

  @impl true
  def get(key, opts) do
    case repo(opts).query!("SELECT body FROM raw_blobs WHERE ref = $1", [key]) do
      %{rows: [[body]]} -> {:ok, body}
      %{rows: []} -> {:error, :missing}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def exists?(key, opts) do
    %{rows: rows} = repo(opts).query!("SELECT 1 FROM raw_blobs WHERE ref = $1", [key])
    rows != []
  end

  @impl true
  def delete(key, opts) do
    repo(opts).query!("DELETE FROM raw_blobs WHERE ref = $1", [key])
    :ok
  rescue
    e -> {:error, e}
  end

  @impl true
  def list_older_than(unix, opts) do
    %{rows: rows} = repo(opts).query!("SELECT ref FROM raw_blobs WHERE created_at <= $1", [unix])
    {:ok, Enum.map(rows, fn [ref] -> ref end)}
  rescue
    e -> {:error, e}
  end

  defp repo(opts), do: Keyword.get(opts, :repo, @default_repo)
end
