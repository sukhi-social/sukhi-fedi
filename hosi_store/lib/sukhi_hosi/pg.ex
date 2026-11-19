# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Pg do
  @moduledoc """
  The part that stays in PostgreSQL. Delivery is Oban's (sukhi's `outbox` table and its relay are
  not touched); this module only has what the feeder needs: the `outbox` table in sukhi's shape
  (plus `source_id`, the hosigraph id of the line, as a second guard), the feeder's cursor, and
  `account_closings` (how far the job that closes an account has got; sukhi's `account_deletions` row),
  `markers` (where each person has read up to; written more than read, and thrown away with the
  account, so it is not hosigraph's).
  """

  @ddl [
    """
    CREATE TABLE IF NOT EXISTS outbox (
      id bigserial PRIMARY KEY,
      aggregate_type text NOT NULL,
      aggregate_id text NOT NULL,
      subject text NOT NULL,
      payload jsonb NOT NULL,
      headers jsonb NOT NULL DEFAULT '{}',
      status text NOT NULL DEFAULT 'pending',
      attempts integer NOT NULL DEFAULT 0,
      last_error text,
      published_at timestamptz,
      source_id bigint UNIQUE,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """,
    "CREATE TABLE IF NOT EXISTS hosi_feeder_cursor (name text PRIMARY KEY, at bigint NOT NULL DEFAULT 0)",
    """
    CREATE TABLE IF NOT EXISTS account_closings (
      account_id bigint PRIMARY KEY,
      actor_deleted_at timestamptz,
      finished_at timestamptz
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS markers (
      account_id bigint NOT NULL,
      timeline text NOT NULL,
      last_read_id text NOT NULL,
      version integer NOT NULL DEFAULT 1,
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (account_id, timeline)
    )
    """
  ]

  def start_link(opts \\ []) do
    Postgrex.start_link(
      hostname: "127.0.0.1",
      port: Keyword.fetch!(opts, :port),
      username: "postgres",
      password: "postgres",
      database: System.get_env("HOSI_PG_DB", "postgres"),
      pool_size: Keyword.get(opts, :pool_size, 3),
      name: Keyword.get(opts, :name)
    )
  end

  def migrate!(pg), do: Enum.each(@ddl, &Postgrex.query!(pg, &1, []))

  def reset!(pg), do: Postgrex.query!(pg, "TRUNCATE outbox, hosi_feeder_cursor, markers, account_closings RESTART IDENTITY", [])

  def outbox_rows(pg) do
    %{rows: rows} =
      Postgrex.query!(pg, "SELECT subject, aggregate_type, aggregate_id, payload, source_id FROM outbox ORDER BY id", [])

    for [subject, type, agg, payload, source] <- rows,
        do: %{subject: subject, type: type, aggregate_id: agg, payload: payload, source_id: source}
  end
end
