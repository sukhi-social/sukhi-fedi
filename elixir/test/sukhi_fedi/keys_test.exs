# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.KeysTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Keys
  alias SukhiFedi.Schema.Account

  describe "new_attrs/0" do
    test "is the five key columns of a new owner, with matching halves" do
      attrs = Keys.new_attrs()

      assert Map.keys(attrs) |> Enum.sort() ==
               ~w(ed25519_private_key_jwk ed25519_public_multibase private_key_jwk public_key_jwk public_key_pem)a

      assert attrs.public_key_pem =~ "BEGIN PUBLIC KEY"
      assert attrs.public_key_jwk["n"] == attrs.private_key_jwk["n"]
      assert is_binary(attrs.private_key_jwk["d"])
      assert attrs.ed25519_private_key_jwk["crv"] == "Ed25519"
    end

    test "two calls never give the same key" do
      refute Keys.new_attrs().private_key_jwk == Keys.new_attrs().private_key_jwk
    end

    test "can build an Account struct as is" do
      assert %Account{private_key_jwk: %{}} = struct!(Account, Keys.new_attrs())
    end
  end

  describe "identity/2" do
    test "names the account's main key and carries both JWKs" do
      account = %Account{
        username: "alice",
        private_key_jwk: %{"kty" => "RSA", "d" => "x"},
        public_key_jwk: %{"kty" => "RSA"}
      }

      assert Keys.identity(account, "a.example") == %{
               keyId: "https://a.example/users/alice#main-key",
               privateJwk: %{"kty" => "RSA", "d" => "x"},
               publicJwk: %{"kty" => "RSA"}
             }
    end

    test "is nil without an account or without a private key" do
      assert Keys.identity(nil, "a.example") == nil
      assert Keys.identity(%Account{username: "bob"}, "a.example") == nil
    end
  end
end
