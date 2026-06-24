# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddSearchConsentToAccounts do
  use Ecto.Migration

  @moduledoc """
  Search-indexing consent for actors (FEP-5feb), as the two flags
  Mastodon already federates under its `toot:` namespace:

    * `discoverable` — may this actor surface in discovery places
      (profile directories, "who to follow" suggestions)?
    * `indexable` — may this actor's posts be picked up by full-text
      search engines and remote indexers?

  Both default to `false`: consent is something a person gives, not a
  thing taken by default. A user turns either on from settings; the
  choice then rides on the actor JSON both ActorJson modules build, so
  remote servers honour it the same way ours would.
  """

  def up do
    alter table(:accounts) do
      add(:discoverable, :boolean, null: false, default: false)
      add(:indexable, :boolean, null: false, default: false)
    end
  end

  def down do
    alter table(:accounts) do
      remove(:discoverable)
      remove(:indexable)
    end
  end
end
