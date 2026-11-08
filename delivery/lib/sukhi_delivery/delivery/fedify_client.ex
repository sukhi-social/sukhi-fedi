# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Delivery.FedifyClient do
  @moduledoc """
  NATS Micro client for the `fedify` service (served by the gateway's
  `SukhiFedi.Fedi.Service`).

  Wraps request/reply to the service endpoints:

    * `fedify.translate.v1` — build ActivityPub JSON-LD from a domain object
    * `fedify.verify.v1`    — verify an incoming signed HTTP request

  There is no sign endpoint: the delivery worker signs in process with
  `SukhiShared.HttpSignature`, so a private key never rides NATS.

  In the single-BEAM `combined` release the service is in this very VM, so
  the release names it (`config :sukhi_delivery, :fedify_service, Mod`) and
  these calls go to `Mod.call/2` directly: same JSON-shaped answers, no
  socket hop to ourselves, and no NATS connection of our own
  (`SukhiDelivery.Application`). Unset (separate delivery node): NATS.

  The service is queue-grouped (`fedify-workers`) on the Bun side so
  multiple replicas share load automatically.
  """

  @timeout 10_000

  @spec translate(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def translate(object_type, payload) when is_binary(object_type) and is_map(payload) do
    request("fedify.translate.v1", %{object_type: object_type, payload: payload})
  end

  @doc "The in-process service module, or nil when this node reaches it over NATS."
  @spec local_service() :: module() | nil
  def local_service, do: Application.get_env(:sukhi_delivery, :fedify_service)

  @spec verify(map()) :: {:ok, term()} | {:error, term()}
  def verify(payload) when is_map(payload) do
    request("fedify.verify.v1", payload)
  end

  @spec ping() :: :ok | {:ok, binary()} | {:error, term()}
  def ping do
    if local_service(), do: :ok, else: ping_nats()
  end

  defp ping_nats do
    case Gnat.request(:gnat_delivery, "fedify.ping.v1", "pong", receive_timeout: @timeout) do
      {:ok, %{body: "pong"}} -> :ok
      {:ok, %{body: other}} -> {:ok, other}
      {:error, _} = err -> err
    end
  end

  defp request(subject, payload) do
    case local_service() do
      nil -> request_nats(subject, payload)
      service -> service.call(subject, payload)
    end
  end

  defp request_nats(subject, payload) do
    body = JSON.encode!(payload)

    case Gnat.request(:gnat_delivery, subject, body, receive_timeout: @timeout) do
      {:ok, %{body: reply}} ->
        case JSON.decode(reply) do
          {:ok, %{"ok" => true, "data" => data}} -> {:ok, data}
          {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
          {:ok, other} -> {:error, {:invalid_envelope, other}}
          {:error, _} = err -> err
        end

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _} = err ->
        err
    end
  end
end
