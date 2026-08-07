# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.Verifier do
  @moduledoc """
  Inbound HTTP-signature verification (`fedify.verify.v1`).

  Resolves the signing key named by the `Signature` header's `keyId`
  (fetching the actor/key document), then delegates the cryptographic
  and policy checks to `Fedi.HttpSignature.verify/5`.

  On success the result names *who* signed — `keyId` and the key's
  `owner` — because the inbox controller binds the signer's host to the
  activity's claimed `actor` (`Instructions.trusted_inline_origin?/2`).
  Verifying bytes without that binding would let any server sign
  activities for anyone, which is exactly the hole the security audit
  closed.

  Key documents are cached; a signature that fails against a cached key
  is retried once against a freshly fetched copy, so key rotation on the
  remote side doesn't strand its followers (same behavior as fedify).
  """

  require Logger

  alias SukhiFedi.Fedi.{Fetcher, HttpSignature, JWK}

  @type fetch_fun :: (String.t(), [:fresh] -> {:ok, map()} | {:error, term()})

  @doc """
  Verifies a `fedify.verify.v1` payload. Returns the Bun-compatible
  result map: `%{"ok" => true, "keyId" => …, "owner" => …}` on success,
  `%{"ok" => false}` when the signature does not check out.
  """
  @spec verify(map(), fetch_fun()) :: {:ok, map()} | {:error, term()}
  def verify(payload, fetch_fun \\ &Fetcher.fetch_cached/2)

  def verify(%{"raw" => raw, "headers" => headers, "method" => method, "url" => url}, fetch_fun) do
    headers = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

    with {:ok, key_id} <- HttpSignature.key_id(headers),
         {:ok, result} <- check(method, url, headers, raw, key_id, fetch_fun) do
      {:ok, result}
    else
      # No/odd signature header, unresolvable key, bad PEM, failed
      # verification — all the same answer for the controller: reject.
      reason ->
        # TEMP: ff.lapy.link 401 investigation (2026-08-07) — the reason was
        # discarded here with no logging anywhere in the call chain, so the
        # controller's 401 carried no clue why. Remove once diagnosed.
        Logger.warning(
          "fedi verify rejected: #{inspect(reason)} url=#{url} " <>
            "signature=#{inspect(Map.get(headers, "signature"))} " <>
            "signature-input=#{inspect(Map.get(headers, "signature-input"))}"
        )

        {:ok, %{"ok" => false}}
    end
  end

  def verify(_payload, _fetch_fun), do: {:ok, %{"ok" => false}}

  defp check(method, url, headers, raw, key_id, fetch_fun, retried? \\ false) do
    with {:ok, document} <- fetch_fun.(key_id, if(retried?, do: [:fresh], else: [])),
         {:ok, pem, owner} <- find_public_key(document, key_id),
         {:ok, public_key} <- JWK.public_key_from_pem(pem) do
      case HttpSignature.verify(method, url, headers, raw, public_key) do
        :ok ->
          {:ok, %{"ok" => true, "keyId" => key_id, "owner" => owner}}

        {:error, :bad_signature} when not retried? ->
          # The cached key may be stale (remote rotated it). One retry
          # against a fresh fetch before giving up.
          check(method, url, headers, raw, key_id, fetch_fun, true)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The keyId document is either the actor (with a `publicKey` member,
  # single or list) or a standalone key document carrying
  # `publicKeyPem` directly.
  #
  # TODO(FEP-521a): fedify-family actors (hackers.pub, Hollo) also
  # publish `assertionMethod` Multikey entries (`publicKeyMultibase`,
  # RSA + Ed25519). We only read the legacy `publicKey` PEM, which every
  # current peer still ships; parse Multikey here the day one stops.
  defp find_public_key(%{"publicKey" => public_key} = document, key_id) do
    entries = List.wrap(public_key)

    entry =
      Enum.find(entries, fn entry -> is_map(entry) and entry["id"] == key_id end) ||
        match_single(entries)

    case entry do
      %{"publicKeyPem" => pem} = entry when is_binary(pem) ->
        {:ok, pem, entry["owner"] || entry["controller"] || document["id"]}

      _ ->
        {:error, :key_not_found}
    end
  end

  defp find_public_key(%{"publicKeyPem" => pem} = document, _key_id) when is_binary(pem) do
    {:ok, pem, document["owner"] || document["controller"] || document["id"]}
  end

  defp find_public_key(_document, _key_id), do: {:error, :key_not_found}

  # Some servers publish exactly one key without repeating its id in a
  # resolvable form; fedify accepts that, so do we.
  defp match_single([entry]) when is_map(entry), do: entry
  defp match_single(_), do: nil
end
