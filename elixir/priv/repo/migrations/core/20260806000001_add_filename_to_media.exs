# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddFilenameToMedia do
  use Ecto.Migration

  def change do
    alter table(:media) do
      # The original filename from the upload's multipart part. Was
      # parsed already (for the storage key's extension) but discarded
      # before this — kept now so a non-image Clip can show a real name
      # instead of just "file.pdf". Existing rows: NULL, harmless.
      add :filename, :string
    end
  end
end
