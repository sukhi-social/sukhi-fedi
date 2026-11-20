# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrations.CreateOutboxAndAudits do
  @moduledoc false
  # The outbox, the admin audit log and the account deletions, as they stand,
  # taken the same way as the first migration: from a database the earlier
  # migrations had been run on. A change from here is a new migration, by hand.
  use Ecto.Migration

  def change do
    create table(:outbox, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :aggregate_type, :string, null: false
      add :aggregate_id, :string, null: false
      add :subject, :string, null: false
      add :payload, :jsonb, null: false
      add :headers, :jsonb, default: fragment("'{}'::jsonb"), null: false
      add :status, :string, default: fragment("'pending'::character varying"), null: false
      add :attempts, :integer, default: 0, null: false
      add :last_error, :text
      add :inserted_at, :timestamp, default: fragment("now()"), null: false
      add :published_at, :timestamp
    end
    create index(:outbox, [:aggregate_type, :aggregate_id], name: :outbox_aggregate_type_aggregate_id_index)
    create index(:outbox, [:id], name: :outbox_pending_id_index, where: "((status)::text = 'pending'::text)")

    create table(:admin_audits, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :action, :string, null: false
      add :admin_account_id, :bigint
      add :target_account_id, :bigint
      add :target_domain, :string
      add :reason, :text
      add :metadata, :jsonb, default: fragment("'{}'::jsonb"), null: false
      add :created_at, :"timestamp(0)", null: false
    end
    create index(:admin_audits, [:action], name: :admin_audits_action_index)
    create index(:admin_audits, [:created_at], name: :admin_audits_created_at_index)

    create table(:account_deletions, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :account_id, references(:accounts, type: :bigint), null: false
      add :requested_at, :"timestamp(0)", null: false
      add :scheduled_for, :"timestamp(0)", null: false
      add :cancelled_at, :"timestamp(0)"
      add :started_at, :"timestamp(0)"
      add :finished_at, :"timestamp(0)"
    end
    create unique_index(:account_deletions, [:account_id], name: :account_deletions_live_index, where: "((cancelled_at IS NULL) AND (finished_at IS NULL))")
    create index(:account_deletions, [:scheduled_for], name: :account_deletions_scheduled_for_index, where: "((cancelled_at IS NULL) AND (finished_at IS NULL))")
  end
end
