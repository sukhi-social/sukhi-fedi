# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddTranslateAutoToAccounts do
  use Ecto.Migration

  @moduledoc """
  Whether a person has turned on quiet auto-translation (docs/TRANSLATION_AUTO.md):
  the page translates posts in languages they do not read as those posts stay on
  screen. Off by default; `SukhiFedi.Translate` refuses an `auto` request from an
  account where this is not `true`.
  """

  def change do
    alter table(:accounts) do
      add(:translate_auto, :boolean, null: false, default: false)
    end
  end
end
