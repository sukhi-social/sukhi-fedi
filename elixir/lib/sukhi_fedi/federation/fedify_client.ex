# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.FedifyClient do
  @moduledoc """
  The gateway's way into the fedify operations.

  They used to be NATS request/reply to `fedify.*.v1`, answered by
  `SukhiFedi.Fedi.Service` -- in this very node. Since v0.3.0 the service
  is native Elixir, so the round trip only added a socket hop, a 10 s
  timeout and a JSON encode/decode on each side. This calls the service
  in-process (`Fedi.Service.call/2` keeps the JSON-shaped input and output,
  so callers see what the reply used to carry).

  The delivery node has no `Fedi.*` and keeps its own client over NATS.
  """

  alias SukhiFedi.Fedi.Service

  @doc "Build ActivityPub JSON-LD from a domain object."
  @spec translate(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def translate(object_type, payload) when is_binary(object_type) and is_map(payload) do
    Service.call("fedify.translate.v1", %{object_type: object_type, payload: payload})
  end

  @doc "Sign an outbound HTTP request envelope."
  @spec sign(map()) :: {:ok, term()} | {:error, term()}
  def sign(payload) when is_map(payload), do: Service.call("fedify.sign.v1", payload)

  @doc "Verify an incoming signed HTTP request."
  @spec verify(map()) :: {:ok, term()} | {:error, term()}
  def verify(payload) when is_map(payload), do: Service.call("fedify.verify.v1", payload)

  @doc "Parse an incoming activity into an instruction."
  @spec inbox(map()) :: {:ok, term()} | {:error, term()}
  def inbox(payload) when is_map(payload), do: Service.call("fedify.inbox.v1", payload)

  @doc """
  Fetch a remote ActivityPub document. When `sign_as` is a
  `%{keyId, privateJwk, ...}` map the GET is HTTP-signed (needed by
  Mastodon Secure Mode / Misskey auth-fetch-required peers); when it is
  `nil` the fetch is unauthenticated. Returns `{:ok, %{"document" => …}}`.
  """
  @spec fetch(String.t(), map() | nil) :: {:ok, term()} | {:error, term()}
  def fetch(uri, sign_as \\ nil) when is_binary(uri) do
    payload = if is_map(sign_as), do: %{uri: uri, signAs: sign_as}, else: %{uri: uri}
    Service.call("fedify.fetch.v1", payload)
  end
end
