# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.FediGolden do
  @moduledoc """
  Loads the golden fixtures `bun/scripts/dump_golden.ts` produced by
  running the real fedify code paths with a fixed keypair. Tests verify
  fedify's outputs with the native code — when that passes, the two
  implementations agree on canonicalization and signing, which is the
  property remote servers depend on.

  Regenerate (only needed when fedify changes):

      cd bun && node --import tsx scripts/dump_golden.ts \\
        > ../elixir/test/support/fixtures/fedify_golden.json
  """

  @fixture Path.expand("fixtures/fedify_golden.json", __DIR__)

  def fixture do
    @fixture |> File.read!() |> JSON.decode!()
  end

  def public_key do
    {:ok, key} = SukhiFedi.Fedi.JWK.public_key(fixture()["publicKeyJwk"])
    key
  end

  def private_key_jwk, do: fixture()["privateKeyJwk"]
  def key_id, do: fixture()["keyId"]
  def actor, do: fixture()["actor"]
  def builder(name), do: fixture()["builders"][name]

  def public_key_pem do
    entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key())
    :public_key.pem_encode([entry])
  end

  # FEP-8b32 Object Integrity Proof fixtures (`oip` section).
  def oip, do: fixture()["oip"]

  def oip_public_key do
    {:ok, key} = SukhiFedi.Fedi.JWK.ed25519_public_key(oip()["publicKeyJwk"])
    key
  end

  def oip_private_key do
    {:ok, key} = SukhiFedi.Fedi.JWK.ed25519_private_key(oip()["privateKeyJwk"])
    key
  end
end
