# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrations.CreateSuspensionIgnores do
  @moduledoc false
  # FEP-f799, stage 6: the rests an admin chose to ignore on this server
  # (docs/DELIVERY_SUSPENSION.md). One row per notice `id`. The notice itself
  # is not touched: the peer's record stays as the peer wrote it; this is only
  # our own local choice not to hold deliveries for it.
  use Ecto.Migration

  def change do
    create table(:suspension_ignores, primary_key: false) do
      add :notice_id, :text, primary_key: true
      add :ignored_at, :bigint, null: false
    end
  end
end
