# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.InviteCode do
  use Ecto.Schema

  schema "invite_codes" do
    field(:code, :string)
    field(:expires_at, :utc_datetime)
    field(:note, :string)
    field(:max_uses, :integer)
    field(:uses_count, :integer)

    # Who minted it (the admin, for audit) vs. who it's attributed to.
    # `on_behalf_of` is nil for a code issued in the issuer's own name.
    belongs_to(:issued_by, SukhiFedi.Schema.Account, foreign_key: :issued_by_id)
    belongs_to(:on_behalf_of, SukhiFedi.Schema.Account, foreign_key: :on_behalf_of_id)

    has_many(:uses, SukhiFedi.Schema.InviteCodeUse)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
