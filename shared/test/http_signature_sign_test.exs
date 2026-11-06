# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.HttpSignatureSignTest do
  use ExUnit.Case, async: true

  # The delivery node signs in process: private JWK -> key -> headers. This
  # is that path end to end, on a fresh key, with nothing but SukhiShared
  # (no gateway module, no NATS). The golden fixtures that pin the bytes
  # against fedify live in elixir/test/sukhi_fedi/fedi/http_signature_test.exs.

  alias SukhiShared.{HttpSignature, JWK}

  @url "https://remote.test/inbox"
  @body ~s({"type":"Create"})
  @key_id "https://sukhi.test/users/alice#main-key"

  defp b64(int), do: int |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)

  setup_all do
    {:RSAPrivateKey, _, n, e, d, p, q, dp, dq, qi, _} =
      :public_key.generate_key({:rsa, 2048, 65_537})

    jwk = %{
      "kty" => "RSA",
      "n" => b64(n),
      "e" => b64(e),
      "d" => b64(d),
      "p" => b64(p),
      "q" => b64(q),
      "dp" => b64(dp),
      "dq" => b64(dq),
      "qi" => b64(qi)
    }

    {:ok, jwk: jwk, public: {:RSAPublicKey, n, e}}
  end

  for spec <- [:cavage, :rfc9421] do
    test "a private JWK signs a POST that verifies (#{spec})", %{jwk: jwk, public: public} do
      {:ok, private_key} = JWK.private_key(jwk)
      headers = HttpSignature.sign_post(@url, @body, private_key, @key_id, spec: unquote(spec))

      assert {:ok, @key_id} = HttpSignature.key_id(headers)
      assert :ok = HttpSignature.verify("post", @url, headers, @body, public)
    end
  end

  test "a tampered body does not verify", %{jwk: jwk, public: public} do
    {:ok, private_key} = JWK.private_key(jwk)
    headers = HttpSignature.sign_post(@url, @body, private_key, @key_id)

    refute :ok == HttpSignature.verify("post", @url, headers, ~s({"type":"Delete"}), public)
  end

  test "a JWK without the private half is refused, not signed with" do
    assert {:error, :invalid_jwk} =
             JWK.private_key(%{"kty" => "RSA", "n" => "AQAB", "e" => "AQAB"})
  end
end
