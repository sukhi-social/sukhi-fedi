# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.InviteCodeUse do
  @moduledoc """
  One person joining on one invite code. A multi-use code has several of
  these; a single-use code has at most one. Recorded inside the signup
  transaction so the count and the joiner commit together.
  """

  use Ecto.Schema

  schema "invite_code_uses" do
    field(:used_at, :utc_datetime)

    belongs_to(:invite_code, SukhiFedi.Schema.InviteCode)
    belongs_to(:account, SukhiFedi.Schema.Account)
  end
end
