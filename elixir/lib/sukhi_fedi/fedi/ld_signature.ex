# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.LdSignature do
  @moduledoc """
  RsaSignature2017 Linked Data signatures — the legacy suite the
  Mastodon-family fediverse actually speaks (newer suites like
  RsaSignature2018/Data Integrity are not understood there).

  The construction mirrors fedify's `signJsonLd`, byte for byte:

      options  = {"@context": identity/v1, creator, created}
      message  = hexsha256(canonize(options)) <> hexsha256(canonize(doc))
      proof    = base64(rsa_pkcs1_sha256(message))

  and the signature block carries the options (including its own
  `@context`) plus `type` and `signatureValue`, attached as the
  document's `signature` member.

  TODO(FEP-8b32): Object Integrity Proofs — the modern successor
  (`proof` member, `eddsa-jcs-2022`, Ed25519). fedify attaches it
  alongside RsaSignature2017 and verifies it preferentially;
  hackers.pub mints an Ed25519 key per actor for exactly this. Needs:
  an Ed25519 actor keypair, JCS canonicalization (the `jcs` hex package
  already rides in our deps via json_ld), and a `proof` builder here.
  Until then RsaSignature2017 keeps Mastodon-level reach.
  """

  alias SukhiFedi.Fedi.{Canon, JWK, Ojak}

  @options_context "https://w3id.org/identity/v1"

  @doc """
  Signs `document` (a JSON-LD map) and returns it with the `signature`
  member attached. `:created` can be injected for deterministic tests.
  """
  @spec sign(map(), JWK.rsa_private_key(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def sign(document, private_key, key_id, opts \\ []) do
    case Ojak.ld_backend() do
      :ojak -> Ojak.ld_sign(document, private_key, key_id, opts)
      :native -> sign_native(document, private_key, key_id, opts)
    end
  end

  defp sign_native(document, private_key, key_id, opts) do
    created = Keyword.get_lazy(opts, :created, &default_created/0)

    options = %{
      "@context" => @options_context,
      "creator" => key_id,
      "created" => created
    }

    with {:ok, message} <- signed_message(options, document) do
      signature_value = :public_key.sign(message, :sha256, private_key) |> Base.encode64()

      signature =
        Map.merge(options, %{"type" => "RsaSignature2017", "signatureValue" => signature_value})

      {:ok, Map.put(document, "signature", signature)}
    end
  end

  @doc """
  Verifies the `signature` member of a signed document. Used by tests to
  prove canonicalization compatibility against fedify-produced fixtures;
  the inbound pipeline relies on HTTP signatures, not on this.
  """
  @spec verify(map(), JWK.rsa_public_key()) :: :ok | {:error, term()}
  def verify(document, public_key) do
    case Ojak.ld_backend() do
      :ojak -> Ojak.ld_verify(document, public_key)
      :native -> verify_native(document, public_key)
    end
  end

  defp verify_native(%{"signature" => signature} = document, public_key) do
    options = %{
      "@context" => @options_context,
      "creator" => signature["creator"],
      "created" => signature["created"]
    }

    with {:ok, encoded} <- decode_signature(signature),
         {:ok, message} <- signed_message(options, Map.delete(document, "signature")) do
      if :public_key.verify(message, :sha256, encoded, public_key) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  defp verify_native(_document, _public_key), do: {:error, :no_signature}

  defp signed_message(options, document) do
    with {:ok, options_hash} <- Canon.hash(options),
         {:ok, document_hash} <- Canon.hash(document) do
      {:ok, options_hash <> document_hash}
    end
  end

  defp decode_signature(%{"signatureValue" => value}) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :bad_signature_encoding}
    end
  end

  defp decode_signature(_), do: {:error, :no_signature}

  # Second precision, no fractional part: already the xsd:dateTime
  # canonical form, so json_ld's canonicalizing literal constructor
  # reproduces it verbatim and the signed hash matches what receivers
  # (which canonize the lexical form as-is) compute. Sub-second
  # precision with >6 fractional digits would be truncated by rdf.ex
  # and break that round trip.
  defp default_created do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
