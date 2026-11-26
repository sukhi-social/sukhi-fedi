# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Poll do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique(:note_id)

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:note_id, to: "notes", on_delete: :cascade, name: "polls_note_id_fkey")

  schema "polls" do
    field(:expires_at, :utc_datetime)
    field(:multiple, :boolean, default: false)
    # Authoritative voter count for a remote poll (from the AP `votersCount`);
    # stays 0 for local polls, which count distinct `poll_votes` instead.
    field(:voters_count, :integer, default: 0)
    belongs_to(:note, SukhiFedi.Schema.Note)
    has_many(:options, SukhiFedi.Schema.PollOption)
    has_many(:votes, SukhiFedi.Schema.PollVote)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(poll, attrs) do
    poll
    |> cast(attrs, [:expires_at, :multiple, :voters_count, :note_id])
    |> validate_required([:note_id])
  end
end
