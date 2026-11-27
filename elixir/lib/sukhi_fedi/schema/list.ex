# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.List do
  use Ecto.Schema
  import Ecto.Changeset

  @replies_policies ~w(followed list none)
  @home_replies ~w(all hide to_me)

  schema "lists" do
    field(:title, :string)
    field(:replies_policy, :string, default: "list")
    field(:exclusive, :boolean, default: false)
    # The list's home gate: conditions a member's post must pass to reach
    # the owner's home timeline. `exclusive` is the strictest setting — admit
    # nothing — and the rest narrow rather than drop. All are ignored for an
    # exclusive list (its members leave home entirely). See
    # `SukhiFedi.Timelines.home/2`.
    field(:filter_only_media, :boolean, default: false)
    field(:filter_hide_boosts, :boolean, default: false)
    field(:filter_hide_sensitive, :boolean, default: false)
    # Admit only posts matching this keyword (a leading `#` → hashtag);
    # nil/"" = no constraint.
    field(:filter_keyword, :string)
    # Replies handling: "all" (no constraint), "hide" (drop replies),
    # "to_me" (admit a reply only if it answers a post on this server).
    field(:filter_replies, :string, default: "all")
    belongs_to(:account, SukhiFedi.Schema.Account)

    many_to_many(:accounts, SukhiFedi.Schema.Account, join_through: "list_accounts")

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at)
  end

  def changeset(list, attrs) do
    list
    |> cast(attrs, [
      :account_id,
      :title,
      :replies_policy,
      :exclusive,
      :filter_only_media,
      :filter_hide_boosts,
      :filter_hide_sensitive,
      :filter_keyword,
      :filter_replies
    ])
    |> validate_required([:account_id, :title])
    |> validate_length(:title, min: 1, max: 100)
    |> validate_inclusion(:replies_policy, @replies_policies)
    |> validate_inclusion(:filter_replies, @home_replies)
  end
end
