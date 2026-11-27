# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.WebauthnCredential do
  use Ecto.Schema

  @moduledoc """
  A registered passkey. `credential_id` is the base64url string the
  browser reports as `credential.id` — stored in that exact form so the
  login lookup is a string equality. `cose_key` is the COSE public key
  map (integer keys, integer/binary values) in external term format;
  decode with `Plug.Crypto.non_executable_binary_to_term/2`.
  """

  schema "webauthn_credentials" do
    field(:credential_id, :string)
    field(:cose_key, :binary)
    field(:sign_count, :integer, default: 0)
    field(:nickname, :string)
    field(:last_used_at, :utc_datetime)

    belongs_to(:account, SukhiFedi.Schema.Account)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
