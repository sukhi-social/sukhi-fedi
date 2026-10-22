# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddAvatarDecorationsToAccounts do
  use Ecto.Migration

  # Misskey (and fork) avatar decorations, mirrored for remote rows only.
  # Each element is `%{"url", "angle", "flip_h", "offset_x", "offset_y"}`
  # (shape fixed by `Account.cast_decorations/1`). Empty = no decoration.
  def change do
    alter table(:accounts) do
      add :avatar_decorations, {:array, :map}, null: false, default: []
    end
  end
end
