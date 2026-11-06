# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.LdSignatureTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Fedi.LdSignature
  alias SukhiShared.JWK
  alias SukhiFedi.FediGolden

  # The compatibility proof: signatures fedify produced (jsonld.js
  # canonize + WebCrypto) must verify through our pipeline (json_ld +
  # rdf.ex + :public_key). If these pass, a Mastodon-family receiver
  # running the same RsaSignature2017 math accepts what we emit.
  describe "verifying fedify-produced golden signatures" do
    # Builder goldens without a `published` timestamp…
    for {name, result_key} <- [{"follow", "follow"}, {"add", "activity"}] do
      test "golden #{name} verifies" do
        document = FediGolden.builder(unquote(name))[unquote(result_key)]
        assert :ok = LdSignature.verify(document, FediGolden.public_key())
      end
    end

    # …and fedify-signed documents in the exact shape (context constant,
    # canonical second-precision timestamps) our Builders emit — nested
    # Note, tags, attachments included before signing.
    for name <- ["announce_canonical", "note_canonical"] do
      test "golden #{name} verifies" do
        document = FediGolden.fixture()["ld_signatures"][unquote(name)]
        assert :ok = LdSignature.verify(document, FediGolden.public_key())
      end
    end

    test "fedify's nanosecond `published` is beyond json_ld.ex — documented limitation" do
      # Temporal stamps 9 fractional digits; rdf.ex literals truncate to
      # microseconds, so canonicalization can't reproduce the lexical
      # form verbatim and verification of *fedify's own* timestamped
      # docs fails. Harmless in production: we only verify our own
      # emissions in tests, and our builders emit second precision
      # (canonical form) — see ld_signature.ex `default_created/0`.
      document = FediGolden.builder("announce")["announce"]
      assert {:error, :bad_signature} = LdSignature.verify(document, FediGolden.public_key())
    end

    test "golden note does NOT verify — post-sign injections break it (known tradeoff)" do
      # bun injected _misskey_content / quote / attachments after
      # signing, so the LD signature never covered them. We keep the
      # same order (receivers rely on the HTTP signature instead).
      document = FediGolden.builder("note")["note"]
      assert {:error, :bad_signature} = LdSignature.verify(document, FediGolden.public_key())
    end

    test "a tampered golden document is rejected" do
      document =
        FediGolden.builder("follow")["follow"]
        |> Map.put("object", "https://evil.example/users/mallory")

      assert {:error, :bad_signature} = LdSignature.verify(document, FediGolden.public_key())
    end
  end

  describe "sign/4" do
    test "round-trips through verify/2" do
      {:ok, private_key} = JWK.private_key(FediGolden.private_key_jwk())

      document = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://sukhi.test/follows/2",
        "type" => "Follow",
        "actor" => FediGolden.actor(),
        "object" => "https://remote.test/users/friend"
      }

      assert {:ok, signed} = LdSignature.sign(document, private_key, FediGolden.key_id())

      assert %{
               "type" => "RsaSignature2017",
               "creator" => creator,
               "created" => _,
               "signatureValue" => _,
               "@context" => "https://w3id.org/identity/v1"
             } = signed["signature"]

      assert creator == FediGolden.key_id()
      assert :ok = LdSignature.verify(signed, FediGolden.public_key())
    end

    test "accepts a pinned :created for determinism" do
      {:ok, private_key} = JWK.private_key(FediGolden.private_key_jwk())
      document = %{"@context" => "https://www.w3.org/ns/activitystreams", "type" => "Follow"}

      assert {:ok, a} =
               LdSignature.sign(document, private_key, FediGolden.key_id(),
                 created: "2026-06-11T00:00:00.000Z"
               )

      assert {:ok, b} =
               LdSignature.sign(document, private_key, FediGolden.key_id(),
                 created: "2026-06-11T00:00:00.000Z"
               )

      # RSASSA-PKCS1-v1_5 is deterministic: same input, same signature.
      assert a["signature"]["signatureValue"] == b["signature"]["signatureValue"]
    end
  end
end
