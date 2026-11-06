# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.OipTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Fedi.{JWK, Oip}
  alias SukhiFedi.FediGolden

  # The compatibility proof, both directions at once: the golden proof
  # was produced by fedify's real `signObject` (and fedify verified the
  # exact fixture JSON before dumping it), and Ed25519 signatures are
  # deterministic (RFC 8032) — so verifying fedify's bytes *and*
  # reproducing them are the same property.
  describe "fedify-produced golden proof" do
    test "verifies with the JWK public key" do
      document = FediGolden.oip()["announce_with_proof"]
      assert :ok = Oip.verify(document, FediGolden.oip_public_key())
    end

    test "verifies with the key decoded from publicKeyMultibase" do
      document = FediGolden.oip()["announce_with_proof"]
      multibase = FediGolden.oip()["multikey"]["publicKeyMultibase"]

      assert {:ok, public_key} = JWK.ed25519_public_key_from_multibase(multibase)
      assert public_key == FediGolden.oip_public_key()
      assert :ok = Oip.verify(document, public_key)
    end

    test "sign/4 reproduces fedify's proofValue byte for byte" do
      golden = FediGolden.oip()["announce_with_proof"]
      document = Map.delete(golden, "proof")

      assert {:ok, signed} =
               Oip.sign(document, FediGolden.oip_private_key(), FediGolden.oip()["keyId"],
                 created: FediGolden.oip()["created"]
               )

      assert signed["proof"]["proofValue"] == golden["proof"]["proofValue"]
    end

    test "a tampered document is rejected" do
      document =
        FediGolden.oip()["announce_with_proof"]
        |> Map.put("object", "https://evil.example/notes/1")

      assert {:error, :bad_proof} = Oip.verify(document, FediGolden.oip_public_key())
    end

    test "a tampered proofValue is rejected" do
      document =
        FediGolden.oip()["announce_with_proof"]
        |> update_in(["proof", "proofValue"], fn "z" <> rest -> "z2" <> rest end)

      assert {:error, :bad_proof} = Oip.verify(document, FediGolden.oip_public_key())
    end
  end

  describe "verify_inbound/2" do
    # The golden actor document publishes the Ed25519 key the
    # fedify-family way: an `assertionMethod` Multikey entry.
    defp fetch_golden_actor(key_id, _opts) do
      assert key_id == FediGolden.oip()["keyId"]
      {:ok, FediGolden.oip()["actor_document"]}
    end

    test "resolves the Multikey from assertionMethod and verifies" do
      document = FediGolden.oip()["announce_with_proof"]
      assert :ok = Oip.verify_inbound(document, &fetch_golden_actor/2)
    end

    test "resolves a standalone Multikey document" do
      document = FediGolden.oip()["announce_with_proof"]
      fetch = fn _key_id, _opts -> {:ok, FediGolden.oip()["multikey"]} end
      assert :ok = Oip.verify_inbound(document, fetch)
    end

    test "rejects when the key's controller is not the activity's actor" do
      # A valid proof by an unrelated key must not authenticate this
      # activity — the binding mirrors the inbox's signer/actor check.
      document =
        FediGolden.oip()["announce_with_proof"]
        |> Map.put("actor", "https://evil.example/users/mallory")

      assert {:error, :bad_proof} = Oip.verify_inbound(document, &fetch_golden_actor/2)
    end

    test "a tampered document is rejected, not passed through" do
      document =
        FediGolden.oip()["announce_with_proof"]
        |> Map.put("object", "https://evil.example/notes/1")

      assert {:error, :bad_proof} = Oip.verify_inbound(document, &fetch_golden_actor/2)
    end

    test "owner: names the member that holds the owner, and a document without it fails" do
      document = FediGolden.oip()["announce_with_proof"]

      assert :ok = Oip.verify_inbound(document, &fetch_golden_actor/2, owner: "actor")

      # a notice-shaped document has no `actor`: asking for `attributedTo`
      # finds nothing to compare, which is a refusal, not a pass
      assert {:error, :bad_proof} =
               Oip.verify_inbound(document, &fetch_golden_actor/2, owner: "attributedTo")
    end

    test "without owner: a document that has no actor is not compared (callers must pass owner:)" do
      document = Map.delete(FediGolden.oip()["announce_with_proof"], "actor")
      # the proof covers `actor`, so deleting it also breaks the proof; what
      # this pins is that the missing member is not itself the failure
      fetch = fn _key_id, _opts -> {:ok, FediGolden.oip()["actor_document"]} end
      assert {:error, :bad_proof} = Oip.verify_inbound(document, fetch)
    end

    test "no proof member → :no_proof (HTTP signature carries the request)" do
      document = Map.delete(FediGolden.oip()["announce_with_proof"], "proof")
      fetch = fn _key_id, _opts -> flunk("must not fetch") end
      assert :no_proof = Oip.verify_inbound(document, fetch)
    end

    test "only foreign cryptosuites → :no_checkable_proof" do
      document =
        FediGolden.oip()["announce_with_proof"]
        |> put_in(["proof", "cryptosuite"], "ecdsa-jcs-2019")

      fetch = fn _key_id, _opts -> flunk("must not fetch") end
      assert :no_checkable_proof = Oip.verify_inbound(document, fetch)
    end

    test "an unresolvable key is a failed proof, not a pass" do
      document = FediGolden.oip()["announce_with_proof"]
      fetch = fn _key_id, _opts -> {:error, :nxdomain} end
      assert {:error, :bad_proof} = Oip.verify_inbound(document, fetch)
    end
  end

  describe "sign/4 round trip" do
    test "signs and verifies with a freshly generated keypair" do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      document = %{
        "@context" => ["https://www.w3.org/ns/activitystreams"],
        "id" => "https://sukhi.test/notes/42/activity",
        "type" => "Create",
        "actor" => "https://sukhi.test/users/shiro",
        "object" => %{"type" => "Note", "content" => "<p>ことば</p>"}
      }

      assert {:ok, signed} = Oip.sign(document, private_key, "https://sukhi.test/users/shiro#ed25519-key")

      assert %{
               "type" => "DataIntegrityProof",
               "cryptosuite" => "eddsa-jcs-2022",
               "proofPurpose" => "assertionMethod",
               "created" => _,
               "proofValue" => "z" <> _
             } = signed["proof"]

      assert :ok = Oip.verify(signed, public_key)
    end

    test "the proof excludes the legacy signature member (fedify strips it before verifying)" do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      document = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://sukhi.test/announces/7",
        "type" => "Announce",
        "signature" => %{"type" => "RsaSignature2017", "signatureValue" => "…"}
      }

      assert {:ok, signed} = Oip.sign(document, private_key, "https://sukhi.test/users/shiro#ed25519-key")
      # signature stays attached but is not covered: replacing it must
      # not invalidate the proof.
      assert :ok = Oip.verify(Map.delete(signed, "signature"), public_key)
      assert :ok = Oip.verify(Map.put(signed, "signature", %{"other" => true}), public_key)
    end
  end

  describe "JWK multibase helpers" do
    test "ed25519_multibase round-trips the golden multikey" do
      multibase = FediGolden.oip()["multikey"]["publicKeyMultibase"]
      assert {:ok, key} = JWK.ed25519_public_key_from_multibase(multibase)
      assert JWK.ed25519_multibase(key) == multibase
    end

    test "rejects a multibase value with the wrong multicodec prefix" do
      # An RSA Multikey (or anything not ed25519-pub) must not decode.
      bogus = JWK.multibase_base58btc(<<0x12, 0x34>> <> :binary.copy(<<7>>, 32))
      assert {:error, :invalid_multikey} = JWK.ed25519_public_key_from_multibase(bogus)
    end
  end
end
