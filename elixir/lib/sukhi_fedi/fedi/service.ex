# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.Service do
  @moduledoc """
  NATS Micro server for the `fedify.*.v1` subjects — the drop-in
  replacement for the Bun fedify service. Same subjects, same queue
  group, same `{ok, data} | {ok: false, error}` envelope, so neither
  `Federation.FedifyClient` (gateway) nor `Delivery.FedifyClient`
  (delivery node) changes at all. While both servers run they share the
  `fedify-workers` queue group; stop the Bun container and this one has
  the floor.

  This module is only the wire adapter: decode, dispatch, encode. The
  gateway's own `Federation.FedifyClient` skips the wire and calls `call/2`
  directly: same dispatch, same JSON-shaped result, no NATS hop to itself.
  The
  actual properties live where they belong — signing policy in
  `HttpSignature`, canonicalization in `Canon`, SSRF in `UrlGuard` via
  `Fetcher`, signer/actor binding in `Verifier` + the inbox controller.

  FEP roadmap for fedify-family interop (hackers.pub, Hollo) — each
  TODO sits at the code site where the work lands:

    * FEP-044f quote posts: `quote` property + QuoteRequest /
      QuoteAuthorization round trip — `Builders.inject_quote/2`,
      `Inbox` (next to the Follow → Accept flow)
    * FEP-8b32 Object Integrity Proofs (Ed25519, eddsa-jcs-2022) —
      `LdSignature` moduledoc
    * FEP-521a Multikey actor keys — `Verifier.find_public_key/2`
    * FEP-8fcf follower collection synchronization: the gateway already
      *consumes* the `Collection-Synchronization` header
      (InboxController → FollowerSyncWorker); *emitting* it on our
      deliveries belongs to the delivery worker's POST, not here
    * FEP-e232 object links for quotes: already emitted
      (`Builders.inject_quote/2` tag Link)
  """

  use Gnat.Server

  require Logger

  alias SukhiFedi.Fedi.{Builders, Fetcher, HttpSignature, Inbox, JWK, Verifier}

  @impl true
  def request(%{topic: "fedify.ping.v1", body: body}), do: {:reply, body}

  def request(%{topic: topic, body: body}) do
    reply =
      case JSON.decode(body) do
        {:ok, payload} -> dispatch(topic, payload)
        {:error, _} -> {:error, "invalid JSON payload"}
      end

    case reply do
      {:ok, data} -> {:reply, JSON.encode!(%{ok: true, data: data})}
      {:error, reason} -> {:reply, JSON.encode!(%{ok: false, error: describe(reason)})}
    end
  end

  @doc """
  The same dispatch `request/1` does for a NATS message, without the NATS.

  The payload goes through a JSON round trip first and so does the result,
  so a caller sees exactly what a NATS reply would have given it: string
  keys, JSON types, errors as strings. (The handlers match on string keys;
  atom-keyed maps and tuples inside a result would otherwise leak out.)
  """
  @spec call(String.t(), map()) :: {:ok, term()} | {:error, String.t()}
  def call(topic, payload) when is_binary(topic) and is_map(payload) do
    case dispatch(topic, json_shape(payload)) do
      {:ok, data} -> {:ok, json_shape(data)}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp json_shape(term), do: term |> JSON.encode!() |> JSON.decode!()

  defp dispatch(topic, payload) do
    handle(topic, payload)
  rescue
    # Parity with the Bun handlers' try/catch: a crash on one request
    # becomes an error envelope, not a dead consumer.
    error ->
      Logger.error("fedi.service #{topic} raised: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  defp handle("fedify.translate.v1", %{"object_type" => type, "payload" => payload}),
    do: Builders.build(type, payload)

  defp handle("fedify.sign.v1", payload), do: sign_delivery(payload)

  defp handle("fedify.verify.v1", payload), do: Verifier.verify(payload)

  defp handle("fedify.inbox.v1", payload), do: Inbox.handle(payload)

  defp handle("fedify.fetch.v1", %{"uri" => uri} = payload),
    do: Fetcher.fetch_document(uri, payload["signAs"])

  defp handle(topic, _payload), do: {:error, "unknown subject: #{topic}"}

  # `fedify.sign.v1` — sign an outbound POST envelope; the delivery
  # worker attaches the returned headers and does the HTTP itself.
  # `algorithm: "rfc9421"` (the per-host override the worker carries
  # for hackers.pub) selects RFC 9421; default stays cavage, the spec
  # every current peer accepts.
  defp sign_delivery(%{"inbox" => inbox, "body" => body, "keyId" => key_id} = payload) do
    spec = if payload["algorithm"] == "rfc9421", do: :rfc9421, else: :cavage

    with {:ok, private_key} <- JWK.private_key(payload["privateKeyJwk"] || %{}) do
      {:ok, %{"headers" => HttpSignature.sign_post(inbox, body, private_key, key_id, spec: spec)}}
    end
  end

  defp sign_delivery(_payload), do: {:error, "sign payload missing inbox/body/keyId"}

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
