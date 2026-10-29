# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddNotificationPaceToAccounts do
  use Ecto.Migration

  @moduledoc """
  A person's own pace for ambient notifications (SukhiFedi.Notifications).

  `notification_hold_minutes` — how long a favourite / boost / follow waits
  before it shows in the list. NULL means "never chosen": the gateway treats
  it as 0 (nothing held), and a client that has a house default (web-unpoly
  asks for an hour) may set it once, because NULL says nobody decided yet.
  `notification_grouping` — collapse ambient notifications of one kind
  (same post, or the same type) into one row.
  """

  def change do
    alter table(:accounts) do
      add(:notification_hold_minutes, :integer)
      add(:notification_grouping, :boolean, null: false, default: false)
    end
  end
end
