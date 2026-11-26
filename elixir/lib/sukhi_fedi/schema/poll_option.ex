# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PollOption do
  use Ecto.Schema
  import Ecto.Changeset

  schema "poll_options" do
    field(:title, :string)
    field(:position, :integer)
    # Cached tally for a remote poll's option (from AP `replies.totalItems`);
    # stays 0 for local options, whose tally is counted from `poll_votes`.
    field(:votes_count, :integer, default: 0)
    belongs_to(:poll, SukhiFedi.Schema.Poll)
    has_many(:votes, SukhiFedi.Schema.PollVote, foreign_key: :option_id)
  end

  def changeset(option, attrs) do
    option
    |> cast(attrs, [:title, :position, :votes_count, :poll_id])
    |> validate_required([:title, :position, :poll_id])
  end
end
