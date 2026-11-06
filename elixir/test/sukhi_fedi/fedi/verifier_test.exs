# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.VerifierTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Fedi.Verifier
  alias SukhiShared.{HttpSignature, JWK}
  alias SukhiFedi.FediGolden

  defp actor_doc do
    %{
      "id" => FediGolden.actor(),
      "type" => "Person",
      "publicKey" => %{
        "id" => FediGolden.key_id(),
        "owner" => FediGolden.actor(),
        "publicKeyPem" => FediGolden.public_key_pem()
      }
    }
  end

  defp key_fetch(doc) do
    fn _uri, _opts -> {:ok, doc} end
  end

  defp signed_payload(body) do
    {:ok, private_key} = JWK.private_key(FediGolden.private_key_jwk())
    headers = HttpSignature.sign_post("https://sukhi.test/inbox", body, private_key, FediGolden.key_id())

    %{
      "raw" => body,
      "headers" => headers,
      "method" => "POST",
      "url" => "https://sukhi.test/inbox"
    }
  end

  test "a valid signature names the key and its owner" do
    payload = signed_payload(~s({"type":"Create"}))

    assert {:ok, %{"ok" => true, "keyId" => key_id, "owner" => owner}} =
             Verifier.verify(payload, key_fetch(actor_doc()))

    assert key_id == FediGolden.key_id()
    assert owner == FediGolden.actor()
  end

  test "publicKey as a list resolves by keyId match" do
    doc =
      Map.put(actor_doc(), "publicKey", [
        %{"id" => "https://sukhi.test/users/shiro#other", "publicKeyPem" => "nope"},
        actor_doc()["publicKey"]
      ])

    assert {:ok, %{"ok" => true}} =
             Verifier.verify(signed_payload("{}"), key_fetch(doc))
  end

  test "a tampered body is rejected" do
    payload = signed_payload(~s({"type":"Create"})) |> Map.put("raw", ~s({"type":"Delete"}))

    assert {:ok, %{"ok" => false}} = Verifier.verify(payload, key_fetch(actor_doc()))
  end

  test "an unsigned request is rejected" do
    payload = %{
      "raw" => "{}",
      "headers" => %{"date" => "whenever"},
      "method" => "POST",
      "url" => "https://sukhi.test/inbox"
    }

    assert {:ok, %{"ok" => false}} = Verifier.verify(payload, key_fetch(actor_doc()))
  end

  test "a stale cached key triggers exactly one fresh refetch" do
    # First call serves a wrong (rotated-away) key; the retry with
    # [:fresh] must serve the real one and verification then succeeds.
    {:ok, wrong_priv} = :public_key.generate_key({:rsa, 2048, 65537}) |> then(&{:ok, &1})
    wrong_pub = {:RSAPublicKey, elem(wrong_priv, 2), elem(wrong_priv, 3)}
    wrong_pem_entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, wrong_pub)
    wrong_doc = put_in(actor_doc()["publicKey"]["publicKeyPem"], :public_key.pem_encode([wrong_pem_entry]))

    test_pid = self()

    fetch = fn _uri, opts ->
      send(test_pid, {:fetched, opts})
      if :fresh in opts, do: {:ok, actor_doc()}, else: {:ok, wrong_doc}
    end

    assert {:ok, %{"ok" => true}} = Verifier.verify(signed_payload("{}"), fetch)
    assert_received {:fetched, []}
    assert_received {:fetched, [:fresh]}
  end

  test "an unresolvable key is a rejection, not a crash" do
    fetch = fn _uri, _opts -> {:error, {:http_status, 410}} end
    assert {:ok, %{"ok" => false}} = Verifier.verify(signed_payload("{}"), fetch)
  end
end
