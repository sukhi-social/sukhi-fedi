# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrations.WidenShortColumns do
  @moduledoc false
  # Columns whose `varchar` was narrower than what the app lets through: it
  # counts graphemes where PostgreSQL counts code points, or has no limit of
  # its own. How long these may be is decided where they come in, not here.
  use Ecto.Migration

  def change do
    alter table(:invite_codes) do
      modify :note, :text, from: :string
    end

    alter table(:webauthn_credentials) do
      modify :nickname, :text, from: :string
      modify :credential_id, :text, from: :string
    end

    alter table(:join_applications) do
      modify :call_name, :text, from: {:string, size: 80}
    end
  end
end
