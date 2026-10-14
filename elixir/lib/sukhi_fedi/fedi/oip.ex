# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.Oip do
  @moduledoc """
  FEP-8b32 Object Integrity Proofs, cryptosuite `eddsa-jcs-2022` — the
  modern successor to RsaSignature2017. fedify-family servers
  (hackers.pub, Hollo) attach one to every activity and verify it
  preferentially over the HTTP signature.

  The construction mirrors fedify's `createProof`, byte for byte:

      proofConfig = {"@context": doc's, type, cryptosuite,
                     verificationMethod, proofPurpose, created}
      hashData    = sha256(jcs(proofConfig)) <> sha256(jcs(unsecured doc))
      proofValue  = multibase(base58btc, ed25519_sign(hashData))

  Two conventions worth naming because they are easy to get wrong:

    * The verifier rebuilds proofConfig from the *document's* `@context`
      and the proof's fields — it does not canonicalize the received
      proof verbatim (extra members like the proof's own `@context` are
      ignored, exactly as fedify does).
    * The proof does not cover the legacy `signature` member. fedify
      attaches RsaSignature2017 *after* the proof and strips it
      (`detachSignature`) before verifying, so both `sign/4` and
      `verify/2` here exclude `signature` from the hashed document.
  """

  alias SukhiFedi.Fedi.{Canon, Fetcher, JWK, Ojak, OjakShadow}

  @cryptosuite "eddsa-jcs-2022"

  @doc """
  Signs `document` with an Ed25519 key (raw 32-byte seed) and returns it
  with the `proof` member attached. Existing `proof`/`signature` members
  are kept in the output but excluded from the signed bytes (see
  moduledoc). `:created` can be injected for deterministic tests.
  """
  @spec sign(map(), JWK.ed25519_private_key(), String.t(), keyword()) :: {:ok, map()}
  def sign(document, private_key, key_id, opts \\ []) do
    created = Keyword.get_lazy(opts, :created, &default_created/0)

    config =
      %{
        "type" => "DataIntegrityProof",
        "cryptosuite" => @cryptosuite,
        "verificationMethod" => key_id,
        "proofPurpose" => "assertionMethod",
        "created" => created
      }
      |> put_document_context(document)

    signature = :crypto.sign(:eddsa, :none, hash_data(config, document), [private_key, :ed25519])
    proof = Map.put(config, "proofValue", JWK.multibase_base58btc(signature))

    {:ok, Map.put(document, "proof", proof)}
  end

  @doc """
  Verifies the document's proof against an already-resolved Ed25519
  public key (raw 32 bytes). With several proofs attached, one valid
  `eddsa-jcs-2022` proof is enough — the others may belong to keys we
  were not given.
  """
  @spec verify(map(), JWK.ed25519_public_key()) :: :ok | {:error, term()}
  def verify(document, public_key) do
    case checkable_proofs(document) do
      [] ->
        {:error, :no_proof}

      proofs ->
        if Enum.any?(proofs, &proof_valid?(document, &1, public_key)) do
          :ok
        else
          {:error, :bad_proof}
        end
    end
  end

  @typep fetch_fun :: (String.t(), [:fresh] -> {:ok, map()} | {:error, term()})

  @doc """
  Verifies an inbound activity's proof, resolving the signing key from
  the proof's `verificationMethod` (a Multikey published in the actor
  document's `assertionMethod`, FEP-521a).

  Returns `:ok` when a proof verifies, `:no_proof` when the document
  carries none, and `:no_checkable_proof` when proofs exist but none
  uses a cryptosuite we implement (the caller decides whether to fall
  back to the HTTP signature; rejecting a suite we cannot check would
  cut off peers that moved past Ed25519).

  The key's `controller` must be the activity's `actor` — a valid proof
  by an unrelated key proves nothing about this activity.
  """
  @spec verify_inbound(map(), fetch_fun()) ::
          :ok | :no_proof | :no_checkable_proof | {:error, term()}
  def verify_inbound(document, fetch_fun \\ &Fetcher.fetch_cached/2)

  def verify_inbound(%{"proof" => _} = document, fetch_fun) do
    case checkable_proofs(document) do
      [] ->
        :no_checkable_proof

      proofs ->
        if Enum.any?(proofs, &resolved_proof_valid?(document, &1, fetch_fun)) do
          :ok
        else
          {:error, :bad_proof}
        end
    end
  end

  def verify_inbound(_document, _fetch_fun), do: :no_proof

  # ── Verification pieces ──────────────────────────────────────────────────

  defp checkable_proofs(document) do
    document
    |> Map.get("proof")
    |> List.wrap()
    |> Enum.filter(fn proof ->
      is_map(proof) and proof["type"] == "DataIntegrityProof" and
        proof["cryptosuite"] == @cryptosuite and
        proof["proofPurpose"] == "assertionMethod" and
        is_binary(proof["created"]) and is_binary(proof["proofValue"]) and
        is_binary(proof["verificationMethod"])
    end)
  end

  # Our verdict, and — when OJAK_SHADOW=1 — a log line if ojak, given this
  # one proof alone, would have said otherwise. The verdict is ours either way.
  defp proof_valid?(document, proof, public_key) do
    valid? = native_proof_valid?(document, proof, public_key)

    OjakShadow.compare(:oip, if(valid?, do: :ok, else: {:error, :bad_proof}), fn ->
      Ojak.verify_proof(Map.put(document, "proof", proof), public_key)
    end)

    valid?
  end

  defp native_proof_valid?(document, proof, public_key) do
    config =
      %{
        "type" => "DataIntegrityProof",
        "cryptosuite" => @cryptosuite,
        "verificationMethod" => proof["verificationMethod"],
        "proofPurpose" => "assertionMethod",
        "created" => proof["created"]
      }
      |> put_document_context(document)

    with {:ok, signature} <- decode_proof_value(proof["proofValue"]) do
      :crypto.verify(:eddsa, :none, hash_data(config, document), signature, [
        public_key,
        :ed25519
      ])
    else
      _ -> false
    end
  end

  defp resolved_proof_valid?(document, proof, fetch_fun, retried? \\ false) do
    key_id = proof["verificationMethod"]

    valid? =
      with {:ok, key_document} <- fetch_fun.(key_id, if(retried?, do: [:fresh], else: [])),
           {:ok, multikey} <- find_multikey(key_document, key_id),
           :ok <- check_controller(multikey, document),
           {:ok, public_key} <-
             JWK.ed25519_public_key_from_multibase(multikey["publicKeyMultibase"] || "") do
        proof_valid?(document, proof, public_key)
      else
        _ -> false
      end

    cond do
      valid? -> true
      # The cached key may be stale (remote rotated it). One retry
      # against a fresh fetch before giving up — same as Verifier.
      retried? -> false
      true -> resolved_proof_valid?(document, proof, fetch_fun, true)
    end
  end

  # The verificationMethod resolves to either a standalone Multikey
  # document or the actor document carrying it in `assertionMethod`.
  defp find_multikey(%{"type" => "Multikey"} = document, _key_id), do: {:ok, document}

  defp find_multikey(document, key_id) when is_map(document) do
    document
    |> Map.get("assertionMethod")
    |> List.wrap()
    |> Enum.find(fn entry -> is_map(entry) and entry["id"] == key_id end)
    |> case do
      %{"type" => "Multikey"} = entry -> {:ok, entry}
      _ -> {:error, :key_not_found}
    end
  end

  defp find_multikey(_document, _key_id), do: {:error, :key_not_found}

  defp check_controller(multikey, document) do
    case actor_uri(document["actor"]) do
      nil -> :ok
      actor -> if multikey["controller"] == actor, do: :ok, else: {:error, :key_actor_mismatch}
    end
  end

  defp actor_uri(uri) when is_binary(uri) and uri != "", do: uri
  defp actor_uri(%{"id" => uri}) when is_binary(uri) and uri != "", do: uri
  defp actor_uri(_), do: nil

  # ── Shared hashing ───────────────────────────────────────────────────────

  defp hash_data(config, document) do
    Canon.jcs_hash(config) <> Canon.jcs_hash(unsecured(document))
  end

  defp unsecured(document) do
    document
    |> Map.delete("proof")
    |> Map.delete("https://w3id.org/security#proof")
    |> Map.delete("signature")
  end

  defp put_document_context(config, %{"@context" => context}),
    do: Map.put(config, "@context", context)

  defp put_document_context(config, _document), do: config

  defp decode_proof_value("z" <> _ = value), do: JWK.from_multibase_base58btc(value)
  defp decode_proof_value(_), do: {:error, :bad_proof_encoding}

  defp default_created do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
