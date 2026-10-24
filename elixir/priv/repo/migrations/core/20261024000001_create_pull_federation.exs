# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.CreatePullFederation do
  use Ecto.Migration

  # Pull Federation (docs/PULL_FEDERATION.md). One migration, because the two
  # nodes share one database and a half-applied set would leave one of them
  # writing a table the other cannot read.
  #
  # Who writes what (ARCHITECTURE §2 rule 2 keeps the core schema the
  # gateway's; these are the narrow projections, like `delivery_receipts`):
  #   delivery  → pull_heads, pull_log, pull_peers          (we are the origin)
  #   gateway   → peer_capabilities, pull_pending,
  #               pull_cursors, pull_hosts                  (we are the puller)
  #   both      → pull_stats, pull_peer_stats, disjoint `kind`s

  def change do
    # What each remote host says it implements (FEP-844e). One row per host:
    # the latest actor document from that host wins.
    create table(:peer_capabilities, primary_key: false) do
      add :host, :text, primary_key: true
      add :hrefs, {:array, :text}, null: false, default: []
      add :seen_at, :utc_datetime_usec, null: false
    end

    # ── origin side ────────────────────────────────────────────────────────
    # Per local actor, the last sequence number handed out. One atomic
    # `ON CONFLICT DO UPDATE ... RETURNING` per appended activity.
    create table(:pull_heads, primary_key: false) do
      add :account_id, :bigint, primary_key: true
      add :seq, :bigint, null: false, default: 0
    end

    # The activities a puller can fetch: exactly the signed bodies we would
    # have POSTed, in per-actor order.
    create table(:pull_log) do
      add :account_id, :bigint, null: false
      add :seq, :bigint, null: false
      add :activity_id, :text, null: false
      add :body, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:pull_log, [:account_id, :seq])
    create unique_index(:pull_log, [:activity_id])
    create index(:pull_log, [:inserted_at])

    # Per remote host that pulls from us: how far through `pull_log` we have
    # told it about, and how its notifications have been going.
    create table(:pull_peers, primary_key: false) do
      add :host, :text, primary_key: true
      add :notified_through, :bigint, null: false, default: 0
      add :notified_at, :utc_datetime_usec
      add :failures, :integer, null: false, default: 0
      add :last_error, :text
    end

    # ── puller side ────────────────────────────────────────────────────────
    # Notifications received and not yet satisfied: one row per (host, actor)
    # holding the newest head that host told us about.
    create table(:pull_pending, primary_key: false) do
      add :host, :text, primary_key: true
      add :actor_uri, :text, primary_key: true
      add :head, :bigint, null: false
      add :received_at, :utc_datetime_usec, null: false
    end

    # How far we have applied each remote actor.
    create table(:pull_cursors, primary_key: false) do
      add :actor_uri, :text, primary_key: true
      add :host, :text, null: false
      add :seq, :bigint, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # Scheduling state per origin host we pull from.
    create table(:pull_hosts, primary_key: false) do
      add :host, :text, primary_key: true
      add :next_pull_at, :utc_datetime_usec, null: false
      add :failures, :integer, null: false, default: 0
      add :last_ok_at, :utc_datetime_usec
      add :last_error, :text
    end

    # ── metrics (admin dashboard) ──────────────────────────────────────────
    # Hourly buckets, one row per (bucket, kind): a counter, the sum and
    # the max of a duration where the kind has one.
    create table(:pull_stats, primary_key: false) do
      add :bucket, :utc_datetime, primary_key: true
      add :kind, :text, primary_key: true
      add :n, :bigint, null: false, default: 0
      add :sum_ms, :bigint, null: false, default: 0
      add :max_ms, :bigint, null: false, default: 0
    end

    # Running totals per peer host and kind, for the "who" table.
    create table(:pull_peer_stats, primary_key: false) do
      add :host, :text, primary_key: true
      add :kind, :text, primary_key: true
      add :n, :bigint, null: false, default: 0
      add :last_at, :utc_datetime_usec, null: false
    end
  end
end
