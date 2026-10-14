# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.OjakTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Fedi.{HttpSignature, JWK, Ojak}
  alias SukhiFedi.FediGolden

  # Same idea as the native tests: fedify made these bytes with a fixed key,
  # and ojak has to accept what we accept (and refuse what we refuse).
  defp golden_now(%{"date" => date}) do
    erl_dt = :httpd_util.convert_request_date(String.to_charlist(date))

    :calendar.datetime_to_gregorian_seconds(erl_dt) -
      :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
  end

  defp verify(%{"headers" => headers, "body" => body, "url" => url} = request, overrides \\ []) do
    Ojak.verify_http_signature(
      Keyword.get(overrides, :method, request["method"]),
      Keyword.get(overrides, :url, url),
      headers,
      Keyword.get(overrides, :body, body),
      FediGolden.public_key_pem(),
      now: golden_now(headers)
    )
  end

  describe "HTTP signatures from fedify" do
    test "cavage verifies" do
      assert :ok = verify(FediGolden.fixture()["http_signature"])
    end

    test "RFC 9421 verifies" do
      assert :ok = verify(FediGolden.fixture()["http_signature_rfc9421"])
    end

    test "a swapped body is refused, in both schemes" do
      for name <- ["http_signature", "http_signature_rfc9421"] do
        assert {:error, _} = verify(FediGolden.fixture()[name], body: ~s({"hello":"mallory"}))
      end
    end

    test "a request signed for another host is refused" do
      request = FediGolden.fixture()["http_signature"]
      assert {:error, _} = verify(request, url: "https://elsewhere.test/inbox")
    end
  end

  describe "HTTP signatures round trip with our own signer" do
    for spec <- [:cavage, :rfc9421] do
      test "#{spec}: ours signs, ojak verifies" do
        {:ok, private_key} = JWK.private_key(FediGolden.private_key_jwk())
        url = "https://sukhi.test/inbox"
        body = ~s({"type":"Create"})

        headers =
          url
          |> HttpSignature.sign_post(body, private_key, FediGolden.key_id(), spec: unquote(spec))
          |> Map.new(fn {name, value} -> {String.downcase(name), value} end)

        assert :ok =
                 Ojak.verify_http_signature(
                   "POST",
                   url,
                   headers,
                   body,
                   FediGolden.public_key_pem()
                 )
      end
    end

    test "the HTTP port counts as part of the host" do
      {:ok, private_key} = JWK.private_key(FediGolden.private_key_jwk())
      url = "https://sukhi.test:8443/inbox?x=1"

      headers =
        url
        |> HttpSignature.sign_post("{}", private_key, FediGolden.key_id())
        |> Map.new(fn {name, value} -> {String.downcase(name), value} end)

      assert :ok =
               Ojak.verify_http_signature("POST", url, headers, "{}", FediGolden.public_key_pem())
    end
  end

  describe "FEP-8b32 proofs" do
    test "the fedify-made proof verifies" do
      document = FediGolden.oip()["announce_with_proof"]
      assert :ok = Ojak.verify_proof(document, FediGolden.oip_public_key())
    end

    test "a tampered document is refused" do
      document =
        FediGolden.oip()["announce_with_proof"]
        |> Map.put("object", "https://remote.test/notes/evil")

      assert {:error, _} = Ojak.verify_proof(document, FediGolden.oip_public_key())
    end

    test "a different key is refused" do
      other = :crypto.strong_rand_bytes(32)
      assert {:error, _} = Ojak.verify_proof(FediGolden.oip()["announce_with_proof"], other)
    end
  end

  describe "RsaSignature2017" do
    test "fedify's documents verify through ojak" do
      for name <- ["announce_canonical", "note_canonical"] do
        document = FediGolden.fixture()["ld_signatures"][name]
        assert :ok = Ojak.ld_verify(document, FediGolden.public_key())
      end
    end

    test "fedify's nanosecond `published` verifies here — the native pipeline cannot" do
      document = FediGolden.builder("announce")["announce"]
      assert :ok = Ojak.ld_verify(document, FediGolden.public_key())
    end

    test "a tampered document is refused with the native atom" do
      document =
        FediGolden.fixture()["ld_signatures"]["announce_canonical"]
        |> Map.put("object", "https://remote.test/notes/evil")

      assert {:error, :bad_signature} = Ojak.ld_verify(document, FediGolden.public_key())
    end

    test "no signature member" do
      assert {:error, :no_signature} =
               Ojak.ld_verify(%{"type" => "Create"}, FediGolden.public_key())
    end

    test "ojak signs a document that ojak verifies; its block carries `expires`" do
      {:ok, private_key} = JWK.private_key(FediGolden.private_key_jwk())

      unsigned =
        Map.delete(FediGolden.fixture()["ld_signatures"]["announce_canonical"], "signature")

      assert {:ok, signed} = Ojak.ld_sign(unsigned, private_key, FediGolden.key_id())
      assert :ok = Ojak.ld_verify(signed, FediGolden.public_key())

      # Mastodon-style options: `expires` is signed along with creator/created,
      # and there is no embedded `@context`. The native verifier rebuilds
      # options from creator + created only, so it cannot check this shape —
      # which is why signing through ojak (OJAK_LD_BACKEND) is a wire change,
      # not a drop-in.
      assert %{"expires" => _} = signed["signature"]
      refute Map.has_key?(signed["signature"], "@context")
    end
  end

  test "both switches default off" do
    refute Ojak.shadow?()
    assert Ojak.ld_backend() == :native
  end
end
