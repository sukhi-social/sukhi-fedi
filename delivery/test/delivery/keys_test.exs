# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.KeysTest do
  use ExUnit.Case, async: true

  alias SukhiDelivery.Keys
  alias SukhiDelivery.Schema.Account

  @actor "https://a.example/users/alice"

  test "an account with both keys gives the RSA and the Ed25519 signing fields" do
    account = %Account{
      private_key_jwk: %{"kty" => "RSA"},
      ed25519_private_key_jwk: %{"kty" => "OKP"}
    }

    assert Keys.signing_fields(account, @actor) == %{
             privateKeyJwk: %{"kty" => "RSA"},
             keyId: @actor <> "#main-key",
             ed25519PrivateKeyJwk: %{"kty" => "OKP"},
             ed25519KeyId: @actor <> "#ed25519-key"
           }
  end

  test "an account without an Ed25519 key signs with the RSA key alone" do
    account = %Account{private_key_jwk: %{"kty" => "RSA"}}

    assert Keys.signing_fields(account, @actor) ==
             %{privateKeyJwk: %{"kty" => "RSA"}, keyId: @actor <> "#main-key"}
  end

  test "no account, or one without a private key, gives nothing" do
    assert Keys.signing_fields(nil, @actor) == %{}
    assert Keys.signing_fields(%Account{}, @actor) == %{}
  end
end
