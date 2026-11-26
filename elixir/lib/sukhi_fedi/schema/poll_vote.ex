# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PollVote do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique([:account_id, :poll_id, :option_id],
    name: "poll_votes_account_id_poll_id_option_id_index"
  )

  schema "poll_votes" do
    belongs_to(:account, SukhiFedi.Schema.Account)
    belongs_to(:poll, SukhiFedi.Schema.Poll)
    belongs_to(:option, SukhiFedi.Schema.PollOption)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:account_id, :poll_id, :option_id])
    |> validate_required([:account_id, :poll_id, :option_id])
    |> unique_constraint([:account_id, :poll_id, :option_id])
  end
end
