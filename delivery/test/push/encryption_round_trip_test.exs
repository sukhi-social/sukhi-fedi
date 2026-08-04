# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Push.EncryptionRoundTripTest do
  @moduledoc """
  Prove that what we encrypt, a browser can decrypt.

  Web Push crypto has one nasty property: when it is subtly wrong it
  fails *silently*. The push service answers 201, we log a success, and
  the phone never buzzes — there is no error anywhere to chase. So this
  is not a "does it run" test; it plays the recipient. It generates a
  subscription keypair, hands the public half to the encrypter, then
  decrypts the body the way a user agent would (RFC 8291 §3.4 + RFC 8188)
  and checks the plaintext came back.

  If the library ever changes its derivation, its framing, or its content
  encoding, this is what says so — out loud, instead of a quiet nothing
  on a lock screen.
  """
  use ExUnit.Case, async: true

  alias WebPush.Encryption

  # A browser subscription, made here so we hold the private half.
  defp subscription do
    {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth_secret = :crypto.strong_rand_bytes(16)

    %{
      p256dh: Base.url_encode64(ua_public, padding: false),
      auth: Base.url_encode64(auth_secret, padding: false),
      ua_public: ua_public,
      ua_private: ua_private,
      auth_secret: auth_secret
    }
  end

  # What a user agent does with the body, written out independently of the
  # library so the two have to agree rather than share a mistake.
  defp decrypt(body, sub) do
    <<salt::binary-16, _rs::32, idlen, rest::binary>> = body
    <<as_public::binary-size(idlen), sealed::binary>> = rest

    ecdh = :crypto.compute_key(:ecdh, as_public, sub.ua_private, :prime256v1)

    prk_key = :crypto.mac(:hmac, :sha256, sub.auth_secret, ecdh)
    key_info = "WebPush: info" <> <<0>> <> sub.ua_public <> as_public
    ikm = expand(prk_key, key_info, 32)

    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    cek = expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)

    tag_size = 16
    ct_size = byte_size(sealed) - tag_size
    <<ciphertext::binary-size(ct_size), tag::binary-size(^tag_size)>> = sealed

    :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)
  end

  defp expand(prk, info, len) do
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, len)
  end

  test "a payload survives the trip to the recipient" do
    sub = subscription()
    plaintext = ~s|{"notification_type":"mention","from":"nyanrus"}|

    padded = Encryption.encrypt(plaintext, sub.p256dh, sub.auth) |> decrypt(sub)

    # RFC 8188 単一レコードの終わりの印。剥がすと、書いたものが返る。
    assert padded == plaintext <> <<2>>
  end

  test "日本語も、そのまま帰ってくる" do
    sub = subscription()
    plaintext = ~s|{"from":"にゃんるす","notification_type":"mention"}|

    assert Encryption.encrypt(plaintext, sub.p256dh, sub.auth) |> decrypt(sub) ==
             plaintext <> <<2>>
  end

  test "the header carries the salt and the sender's key, where a browser looks" do
    sub = subscription()
    body = Encryption.encrypt("hi", sub.p256dh, sub.auth)

    <<salt::binary-16, rs::32, idlen, as_public::binary-size(idlen), _::binary>> = body

    assert byte_size(salt) == 16
    assert rs == 4096
    # An uncompressed P-256 point: 0x04 and two 32-byte coordinates.
    assert idlen == 65
    assert <<4, _::binary>> = as_public
  end

  test "every push gets its own salt and ephemeral key" do
    # Reusing either would leak across messages. Two encryptions of the
    # same text must not produce the same bytes.
    sub = subscription()
    a = Encryption.encrypt("same words", sub.p256dh, sub.auth)
    b = Encryption.encrypt("same words", sub.p256dh, sub.auth)

    assert a != b
    assert binary_part(a, 0, 16) != binary_part(b, 0, 16)
  end

  test "a body edited in flight does not decrypt" do
    # AES-GCM authenticates; flipping one byte must fail, not garble.
    sub = subscription()
    body = Encryption.encrypt("hi", sub.p256dh, sub.auth)

    last = byte_size(body) - 1
    <<head::binary-size(^last), b>> = body
    tampered = head <> <<Bitwise.bxor(b, 1)>>

    assert decrypt(tampered, sub) == :error
  end
end
