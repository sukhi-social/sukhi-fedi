# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.JWK do
  @moduledoc """
  Key material conversions for the native federation service.

  Actor keys live in the DB as JWK maps (the shape WebCrypto's
  `exportJwk` produced when the Bun service generated them); remote
  actor keys arrive as PEM strings (RSA, legacy `publicKey`) or as
  Multikey `publicKeyMultibase` strings (Ed25519, FEP-521a
  `assertionMethod`) inside actor documents. Everything downstream
  (`:public_key.sign/3`, `:crypto.sign/4`, …) wants Erlang terms, so
  the conversions live here and nowhere else.
  """

  @type rsa_private_key :: tuple()
  @type rsa_public_key :: tuple()
  # Raw 32-byte values, the form `:crypto`'s eddsa functions take.
  @type ed25519_public_key :: binary()
  @type ed25519_private_key :: binary()

  @doc "Converts a private RSA JWK map into an `:public_key` RSAPrivateKey record."
  @spec private_key(map()) :: {:ok, rsa_private_key()} | {:error, :invalid_jwk}
  def private_key(%{"kty" => "RSA", "d" => _} = jwk) do
    fields = Enum.map(~w(n e d p q dp dq qi), &int(jwk[&1]))

    if Enum.any?(fields, &is_nil/1) do
      {:error, :invalid_jwk}
    else
      [n, e, d, p, q, dp, dq, qi] = fields
      {:ok, {:RSAPrivateKey, :"two-prime", n, e, d, p, q, dp, dq, qi, :asn1_NOVALUE}}
    end
  end

  def private_key(_), do: {:error, :invalid_jwk}

  @doc "Converts a public RSA JWK map into an `:public_key` RSAPublicKey record."
  @spec public_key(map()) :: {:ok, rsa_public_key()} | {:error, :invalid_jwk}
  def public_key(%{"kty" => "RSA", "n" => n, "e" => e}) do
    case {int(n), int(e)} do
      {n, e} when is_integer(n) and is_integer(e) -> {:ok, {:RSAPublicKey, n, e}}
      _ -> {:error, :invalid_jwk}
    end
  end

  def public_key(_), do: {:error, :invalid_jwk}

  @doc """
  Parses a `publicKeyPem` value from a remote actor document.

  Accepts both SPKI (`BEGIN PUBLIC KEY`, what Mastodon and nearly
  everyone publishes) and PKCS#1 (`BEGIN RSA PUBLIC KEY`).
  """
  @spec public_key_from_pem(String.t()) :: {:ok, rsa_public_key()} | {:error, :invalid_pem}
  def public_key_from_pem(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        case :public_key.pem_entry_decode(entry) do
          {:RSAPublicKey, _, _} = key -> {:ok, key}
          _ -> {:error, :invalid_pem}
        end

      [] ->
        {:error, :invalid_pem}
    end
  rescue
    # pem_entry_decode raises on malformed DER; a remote server's bad
    # key is an input problem, not ours.
    _ -> {:error, :invalid_pem}
  end

  def public_key_from_pem(_), do: {:error, :invalid_pem}

  # ── Ed25519 (OKP JWKs and FEP-521a Multikey) ─────────────────────────────

  @doc "Extracts the raw 32-byte public key from an Ed25519 OKP JWK."
  @spec ed25519_public_key(map()) :: {:ok, ed25519_public_key()} | {:error, :invalid_jwk}
  def ed25519_public_key(%{"kty" => "OKP", "crv" => "Ed25519", "x" => x}) when is_binary(x) do
    case Base.url_decode64(x, padding: false) do
      {:ok, <<key::binary-size(32)>>} -> {:ok, key}
      _ -> {:error, :invalid_jwk}
    end
  end

  def ed25519_public_key(_), do: {:error, :invalid_jwk}

  @doc "Extracts the raw 32-byte private seed from an Ed25519 OKP JWK."
  @spec ed25519_private_key(map()) :: {:ok, ed25519_private_key()} | {:error, :invalid_jwk}
  def ed25519_private_key(%{"kty" => "OKP", "crv" => "Ed25519", "d" => d}) when is_binary(d) do
    case Base.url_decode64(d, padding: false) do
      {:ok, <<key::binary-size(32)>>} -> {:ok, key}
      _ -> {:error, :invalid_jwk}
    end
  end

  def ed25519_private_key(_), do: {:error, :invalid_jwk}

  # multicodec prefix for ed25519-pub, varint-encoded (0xed → 0xed 0x01).
  @ed25519_pub_multicodec <<0xED, 0x01>>

  @doc """
  Decodes a Multikey `publicKeyMultibase` value (`z6Mk…`: base58btc with
  the ed25519-pub multicodec prefix) into the raw 32-byte public key.
  """
  @spec ed25519_public_key_from_multibase(String.t()) ::
          {:ok, ed25519_public_key()} | {:error, :invalid_multikey}
  def ed25519_public_key_from_multibase(value) do
    case from_multibase_base58btc(value) do
      {:ok, @ed25519_pub_multicodec <> <<key::binary-size(32)>>} -> {:ok, key}
      _ -> {:error, :invalid_multikey}
    end
  end

  @doc "Encodes a raw 32-byte Ed25519 public key as a Multikey `publicKeyMultibase` value."
  @spec ed25519_multibase(ed25519_public_key()) :: String.t()
  def ed25519_multibase(<<key::binary-size(32)>>) do
    multibase_base58btc(@ed25519_pub_multicodec <> key)
  end

  @doc "Encodes bytes as a multibase base58btc string (`z` prefix) — the `proofValue` form."
  @spec multibase_base58btc(binary()) :: String.t()
  def multibase_base58btc(bytes) when is_binary(bytes), do: "z" <> base58_encode(bytes)

  @doc "Decodes a multibase base58btc string (`z` prefix) back into bytes."
  @spec from_multibase_base58btc(String.t()) :: {:ok, binary()} | {:error, :invalid_multibase}
  def from_multibase_base58btc("z" <> base58) do
    case base58_decode(base58) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> {:error, :invalid_multibase}
    end
  end

  def from_multibase_base58btc(_), do: {:error, :invalid_multibase}

  # base58btc (RFC draft / Bitcoin alphabet). Small enough that a
  # dependency would cost more than these two folds.
  @base58_alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  defp base58_encode(bytes) do
    {zeros, rest} = split_leading(bytes, 0)
    digits = if rest == <<>>, do: [], else: base58_digits(:crypto.bytes_to_integer(rest), [])
    String.duplicate("1", zeros) <> List.to_string(digits)
  end

  defp base58_digits(0, acc), do: acc

  defp base58_digits(n, acc),
    do: base58_digits(div(n, 58), [Enum.at(@base58_alphabet, rem(n, 58)) | acc])

  defp base58_decode(string) do
    chars = String.to_charlist(string)
    {ones, rest} = Enum.split_while(chars, &(&1 == ?1))

    rest
    |> Enum.reduce_while(0, fn char, acc ->
      case Enum.find_index(@base58_alphabet, &(&1 == char)) do
        nil -> {:halt, :error}
        index -> {:cont, acc * 58 + index}
      end
    end)
    |> case do
      :error -> {:error, :invalid_base58}
      0 -> {:ok, :binary.copy(<<0>>, length(ones))}
      n -> {:ok, :binary.copy(<<0>>, length(ones)) <> :binary.encode_unsigned(n)}
    end
  end

  defp split_leading(<<0, rest::binary>>, count), do: split_leading(rest, count + 1)
  defp split_leading(bytes, count), do: {count, bytes}

  defp int(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> :crypto.bytes_to_integer(bytes)
      :error -> nil
    end
  end

  defp int(_), do: nil
end
