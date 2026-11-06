# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.NodeinfoMonitor.KeyGen do
  @moduledoc """
  Actor keypair generation (originally for bot actors, now every local
  account), producing the shapes ActivityPub + HTTP Signature need:

    * `public_jwk`  — JSON Web Key (RFC 7517), for NATS sign/verify paths
    * `private_jwk` — full private JWK (n, e, d, p, q, dp, dq, qi)
    * `public_pem`  — PEM-wrapped SubjectPublicKeyInfo, for actor JSON's
                       `publicKey.publicKeyPem` field
    * `ed25519_private_jwk`      — OKP JWK, signs FEP-8b32 Object
                                   Integrity Proofs (eddsa-jcs-2022)
    * `ed25519_public_multibase` — the Multikey `publicKeyMultibase`
                                   form, for actor JSON's `assertionMethod`

  Uses Erlang's standard `:public_key`/`:crypto` so no extra dependencies.
  """

  alias SukhiShared.JWK

  @type jwk :: %{required(String.t() | atom()) => String.t()}
  @type result :: %{
          required(:public_jwk) => jwk(),
          required(:private_jwk) => jwk(),
          required(:public_pem) => String.t(),
          required(:ed25519_private_jwk) => jwk(),
          required(:ed25519_public_multibase) => String.t()
        }

  @spec generate() :: result()
  def generate do
    {:RSAPrivateKey, _v, n, e, d, p, q, dp, dq, qi, _} =
      :public_key.generate_key({:rsa, 2048, 65_537})

    public_key = {:RSAPublicKey, n, e}

    pem =
      [:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)]
      |> :public_key.pem_encode()
      |> IO.iodata_to_binary()

    public_jwk = %{
      "kty" => "RSA",
      "alg" => "RS256",
      "use" => "sig",
      "n" => b64url_int(n),
      "e" => b64url_int(e)
    }

    private_jwk =
      Map.merge(public_jwk, %{
        "d" => b64url_int(d),
        "p" => b64url_int(p),
        "q" => b64url_int(q),
        "dp" => b64url_int(dp),
        "dq" => b64url_int(dq),
        "qi" => b64url_int(qi)
      })

    {ed_public, ed_private} = :crypto.generate_key(:eddsa, :ed25519)

    ed25519_private_jwk = %{
      "kty" => "OKP",
      "crv" => "Ed25519",
      "x" => Base.url_encode64(ed_public, padding: false),
      "d" => Base.url_encode64(ed_private, padding: false)
    }

    %{
      public_jwk: public_jwk,
      private_jwk: private_jwk,
      public_pem: pem,
      ed25519_private_jwk: ed25519_private_jwk,
      ed25519_public_multibase: JWK.ed25519_multibase(ed_public)
    }
  end

  defp b64url_int(i) when is_integer(i) do
    i
    |> :binary.encode_unsigned()
    |> Base.url_encode64(padding: false)
  end
end
