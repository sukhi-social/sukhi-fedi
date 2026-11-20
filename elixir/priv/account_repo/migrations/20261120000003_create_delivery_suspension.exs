# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrations.CreateDeliverySuspension do
  @moduledoc false
  # What FEP-f799 remembers (docs/DELIVERY_SUSPENSION.md): four kinds of row,
  # written by hand. Times are microseconds since the epoch
  # (`SukhiFedi.Fedi.DeliverySuspension.Store` turns them into `DateTime`s).
  use Ecto.Migration

  def change do
    # One per notice `id` (its URL). `record` is the whole notice as JSON and is
    # what a read goes back to; the other columns are for finding rows.
    create table(:suspension_notices, primary_key: false) do
      add :id, :text, primary_key: true
      add :controller, :text, null: false
      add :target_kind, :string, null: false
      add :target, :text, null: false
      add :status, :string, null: false
      add :revision, :bigint, null: false
      add :published, :bigint, null: false
      add :create_id, :text
      add :record, :text, null: false
      add :snapshot, :text
    end

    create index(:suspension_notices, [:controller, :create_id])
    create index(:suspension_notices, [:published])

    # An `Undo` that came before the `Create` it undoes, held by `(actor, create_id)`.
    create table(:suspension_pending, primary_key: false) do
      add :actor, :text, primary_key: true
      add :create_id, :text, primary_key: true
      add :received_at, :bigint, null: false
      add :expires_at, :bigint, null: false
    end

    create index(:suspension_pending, [:expires_at])

    # The last time a controller's right to speak for a target was confirmed, and the last try.
    create table(:suspension_evidence, primary_key: false) do
      add :kind, :string, primary_key: true
      add :target, :text, primary_key: true
      add :controller, :text, primary_key: true
      add :verified_at, :bigint
      add :attempted_at, :bigint
      add :failure, :string
    end

    # Per controller: nothing published before this is accepted. Only moves forward.
    create table(:suspension_cutoffs, primary_key: false) do
      add :controller, :text, primary_key: true
      add :not_before, :bigint, null: false
    end
  end
end
