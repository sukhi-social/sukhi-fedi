# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.WebauthnChallenge do
  use Ecto.Schema

  @moduledoc """
  An in-flight WebAuthn ceremony: the `Wax.Challenge` struct (external
  term format) parked between the options request and the browser's
  response. `ref` is the random lookup key the client echoes back;
  `account_id` is NULL for login ceremonies (nobody is signed in yet).
  Rows are one-shot — consumed on use, swept by expiry.
  """

  schema "webauthn_challenges" do
    field(:ref, :string)
    field(:purpose, :string)
    field(:challenge, :binary)
    field(:expires_at, :utc_datetime)

    belongs_to(:account, SukhiFedi.Schema.Account)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
