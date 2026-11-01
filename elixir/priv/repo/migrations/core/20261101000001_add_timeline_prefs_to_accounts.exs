# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddTimelinePrefsToAccounts do
  use Ecto.Migration

  @moduledoc """
  How a person likes their own timeline shown (read back by web-next).

  `home_filter` — the filter the home timeline starts with, a comma list of
  `hide_boosts` / `hide_sensitive` / `only_media`. NULL means none.
  `boost_hide_name` — a boost row leaves out whose post it is.
  """

  def change do
    alter table(:accounts) do
      add(:home_filter, :string)
      add(:boost_hide_name, :boolean, null: false, default: false)
    end
  end
end
