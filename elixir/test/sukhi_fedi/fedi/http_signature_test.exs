# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.HttpSignatureTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Fedi.{HttpSignature, JWK}
  alias SukhiFedi.FediGolden

  defp golden_request, do: FediGolden.fixture()["http_signature"]
  defp golden_request_rfc9421, do: FediGolden.fixture()["http_signature_rfc9421"]

  # Pin the verification clock to the moment the fixture was signed, so
  # the golden tests don't rot as the fixtures age.
  defp golden_now(%{"date" => date}) do
    {{_, _, _}, {_, _, _}} =
      erl_dt = :httpd_util.convert_request_date(String.to_charlist(date))

    :calendar.datetime_to_gregorian_seconds(erl_dt) -
      :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
  end

  describe "verifying the fedify-signed golden request (cavage)" do
    test "accepts it" do
      %{"headers" => headers, "body" => body, "url" => url} = golden_request()

      assert :ok =
               HttpSignature.verify("POST", url, headers, body, FediGolden.public_key(),
                 now: golden_now(headers)
               )
    end

    test "rejects it when the body was swapped" do
      %{"headers" => headers, "url" => url} = golden_request()

      assert {:error, :digest_mismatch} =
               HttpSignature.verify(
                 "POST",
                 url,
                 headers,
                 ~s({"hello":"mallory"}),
                 FediGolden.public_key(),
                 now: golden_now(headers)
               )
    end

    test "rejects it outside the date window" do
      %{"headers" => headers, "body" => body, "url" => url} = golden_request()

      assert {:error, :date_out_of_window} =
               HttpSignature.verify("POST", url, headers, body, FediGolden.public_key(),
                 now: golden_now(headers) + 7200
               )
    end
  end

  describe "verifying the fedify-signed golden request (RFC 9421)" do
    test "accepts it" do
      %{"headers" => headers, "body" => body, "url" => url} = golden_request_rfc9421()
      assert headers["signature-input"] =~ "sig1="

      assert :ok =
               HttpSignature.verify("POST", url, headers, body, FediGolden.public_key(),
                 now: golden_now(headers)
               )
    end

    test "rejects it when the body was swapped" do
      %{"headers" => headers, "url" => url} = golden_request_rfc9421()

      assert {:error, :digest_mismatch} =
               HttpSignature.verify(
                 "POST",
                 url,
                 headers,
                 ~s({"hello":"mallory"}),
                 FediGolden.public_key(),
                 now: golden_now(headers)
               )
    end

    test "rejects it outside the created window" do
      %{"headers" => headers, "body" => body, "url" => url} = golden_request_rfc9421()

      assert {:error, :created_out_of_window} =
               HttpSignature.verify("POST", url, headers, body, FediGolden.public_key(),
                 now: golden_now(headers) + 7200
               )
    end
  end

  describe "sign_post/5 → verify/6 round trip" do
    setup do
      {:ok, private_key} = JWK.private_key(FediGolden.private_key_jwk())
      %{private_key: private_key}
    end

    test "cavage round-trips", %{private_key: private_key} do
      body = ~s({"a":1})

      headers =
        HttpSignature.sign_post(
          "https://remote.test/inbox",
          body,
          private_key,
          FediGolden.key_id()
        )

      assert headers["host"] == "remote.test"
      assert headers["content-type"] == "application/activity+json"
      assert String.starts_with?(headers["digest"], "SHA-256=")
      assert headers["signature"] =~ ~s(keyId="#{FediGolden.key_id()}")

      assert :ok =
               HttpSignature.verify(
                 "POST",
                 "https://remote.test/inbox",
                 headers,
                 body,
                 FediGolden.public_key()
               )
    end

    test "rfc9421 round-trips", %{private_key: private_key} do
      body = ~s({"a":1})

      headers =
        HttpSignature.sign_post(
          "https://remote.test/inbox",
          body,
          private_key,
          FediGolden.key_id(), spec: :rfc9421)

      assert headers["content-digest"] =~ ~r/^sha-256=:.+:$/
      assert headers["signature-input"] =~ ~s(keyid="#{FediGolden.key_id()}")

      assert headers["signature-input"] =~
               ~s["@method" "@target-uri" "@authority" "host" "date" "content-digest"]

      assert headers["signature"] =~ ~r/^sig1=:.+:$/

      assert :ok =
               HttpSignature.verify(
                 "POST",
                 "https://remote.test/inbox",
                 headers,
                 body,
                 FediGolden.public_key()
               )
    end

    test "rfc9421 signed by us verifies through fedify's own verifyRequest shape",
         %{private_key: private_key} do
      # Sanity on the wire format fedify parses: sf inner list + params.
      headers =
        HttpSignature.sign_post(
          "https://remote.test/inbox",
          "x",
          private_key,
          FediGolden.key_id(),
          spec: :rfc9421,
          now: 1_780_000_000
        )

      assert headers["signature-input"] =~
               ~r/;alg="rsa-v1_5-sha256";keyid=".+";created=1780000000$/
    end

    test "a cavage signature that does not cover digest is rejected even when the digest matches",
         %{private_key: private_key} do
      body = ~s({"a":1})

      headers =
        HttpSignature.sign_post(
          "https://remote.test/inbox",
          body,
          private_key,
          FediGolden.key_id()
        )

      # Re-sign covering only (request-target) + host + date: the body
      # is then unbound and verify must refuse — this is the hole the
      # limeburst/feder prototype had, kept closed here by test.
      weak_names = ["(request-target)", "host", "date"]

      message =
        Enum.map_join(weak_names, "\n", fn
          "(request-target)" -> "(request-target): post /inbox"
          name -> "#{name}: #{headers[name]}"
        end)

      weak_sig = :public_key.sign(message, :sha256, private_key) |> Base.encode64()

      weak_headers =
        Map.put(
          headers,
          "signature",
          ~s(keyId="k",algorithm="rsa-sha256",headers="#{Enum.join(weak_names, " ")}",signature="#{weak_sig}")
        )

      assert {:error, :digest_not_signed} =
               HttpSignature.verify(
                 "POST",
                 "https://remote.test/inbox",
                 weak_headers,
                 body,
                 FediGolden.public_key()
               )
    end

    test "an rfc9421 signature that does not cover content-digest is rejected",
         %{private_key: private_key} do
      body = ~s({"a":1})

      headers =
        HttpSignature.sign_post(
          "https://remote.test/inbox",
          body,
          private_key,
          FediGolden.key_id(), spec: :rfc9421)

      # Strip content-digest from the covered components but keep the
      # rest of the envelope: coverage policy must refuse before any
      # crypto runs (the signature itself no longer matters).
      weakened =
        Map.update!(headers, "signature-input", fn input ->
          String.replace(input, ~s( "content-digest"), "")
        end)

      assert {:error, :digest_not_signed} =
               HttpSignature.verify(
                 "POST",
                 "https://remote.test/inbox",
                 weakened,
                 body,
                 FediGolden.public_key()
               )
    end

    test "a body-bearing cavage request without a digest header is rejected",
         %{private_key: private_key} do
      body = ~s({"a":1})

      headers =
        HttpSignature.sign_post(
          "https://remote.test/inbox",
          body,
          private_key,
          FediGolden.key_id()
        )
        |> Map.delete("digest")

      assert {:error, :no_digest} =
               HttpSignature.verify(
                 "POST",
                 "https://remote.test/inbox",
                 headers,
                 body,
                 FediGolden.public_key()
               )
    end

    test "sign_get covers (request-target) host date", %{private_key: private_key} do
      headers =
        HttpSignature.sign_get("https://remote.test/users/x", private_key, FediGolden.key_id())

      assert headers["signature"] =~ ~s(headers="\(request-target\) host date")

      assert :ok =
               HttpSignature.verify(
                 "GET",
                 "https://remote.test/users/x",
                 headers,
                 "",
                 FediGolden.public_key()
               )
    end

    test "sign_get covers the query string in (request-target)", %{private_key: private_key} do
      url = "https://remote.test/users/x/outbox?page=true&until_id=abc"
      headers = HttpSignature.sign_get(url, private_key, FediGolden.key_id())

      # A peer rebuilds the signing string from path *and* query. Dropping
      # the query (the old behaviour) made every paged collection fetch
      # fail verification with a 403.
      assert :ok = HttpSignature.verify("GET", url, headers, "", FediGolden.public_key())

      # The query is genuinely part of what we signed: the same signature
      # must not verify against the query-less URL.
      assert {:error, :bad_signature} =
               HttpSignature.verify(
                 "GET",
                 "https://remote.test/users/x/outbox",
                 headers,
                 "",
                 FediGolden.public_key()
               )
    end

    # The delivery worker double-knocks (cavage ↔ rfc9421), so both specs
    # arrive here over time. verify/6 must route purely on the presence of
    # Signature-Input — neither spec may be coerced into the other's path.
    test "verify routes by Signature-Input presence, no cross-over", %{private_key: private_key} do
      body = ~s({"a":1})

      cavage =
        HttpSignature.sign_post(
          "https://remote.test/inbox",
          body,
          private_key,
          FediGolden.key_id()
        )

      refute Map.has_key?(cavage, "signature-input")

      assert :ok =
               HttpSignature.verify(
                 "POST",
                 "https://remote.test/inbox",
                 cavage,
                 body,
                 FediGolden.public_key()
               )

      rfc =
        HttpSignature.sign_post(
          "https://remote.test/inbox",
          body,
          private_key,
          FediGolden.key_id(), spec: :rfc9421)

      assert Map.has_key?(rfc, "signature-input")

      assert :ok =
               HttpSignature.verify(
                 "POST",
                 "https://remote.test/inbox",
                 rfc,
                 body,
                 FediGolden.public_key()
               )
    end

    # An attacker who can rewrite the Signature-Input must not be able to
    # name a weaker/foreign algorithm and have us shrug it through: the
    # alg whitelist refuses before any signature math runs.
    test "an rfc9421 signature naming an unsupported algorithm is refused before crypto",
         %{private_key: private_key} do
      body = ~s({"a":1})

      headers =
        HttpSignature.sign_post(
          "https://remote.test/inbox",
          body,
          private_key,
          FediGolden.key_id(), spec: :rfc9421)

      downgraded =
        Map.update!(headers, "signature-input", fn input ->
          String.replace(input, ~s(alg="rsa-v1_5-sha256"), ~s(alg="hmac-sha256"))
        end)

      assert {:error, :unsupported_algorithm} =
               HttpSignature.verify(
                 "POST",
                 "https://remote.test/inbox",
                 downgraded,
                 body,
                 FediGolden.public_key()
               )
    end
  end

  describe "key_id/1" do
    test "reads cavage Signature headers" do
      %{"headers" => headers} = golden_request()
      assert {:ok, key_id} = HttpSignature.key_id(headers)
      assert key_id == FediGolden.key_id()
    end

    test "reads rfc9421 Signature-Input headers" do
      %{"headers" => headers} = golden_request_rfc9421()
      assert {:ok, key_id} = HttpSignature.key_id(headers)
      assert key_id == FediGolden.key_id()
    end
  end
end
