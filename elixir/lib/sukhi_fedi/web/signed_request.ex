# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.SignedRequest do
  @moduledoc """
  Who sent this HTTP request? The one place a request's HTTP signature is
  checked at the gateway's edge — the inbox and the Pull Federation
  endpoints both ask here (CODE_STYLE §2: verify first, at the boundary,
  once).

  The signature base binds `host` and the request target. Behind a proxy
  (cloudflared, kamal) the `Host` header and path may have been rewritten to
  internal values, but the remote signed what it sent to our public name, so
  both are rebuilt from the configured `:domain` (`public_url/1`).
  """

  alias SukhiFedi.Federation.FedifyClient

  @type verdict ::
          {:ok, %{signer_host: String.t() | nil, result: map()}} | :unverified | {:error, term()}

  @doc """
  Verify the signature on `conn` (body already read into
  `conn.assigns.raw_body`). `sign_as` is the identity used for the
  key-document fetch, for peers that insist on signed fetches (`nil` ok).
  """
  @spec verify(Plug.Conn.t(), String.t(), map() | nil) :: verdict()
  def verify(conn, method, sign_as) do
    self_domain = Application.get_env(:sukhi_fedi, :domain) || conn.host
    headers = conn.req_headers |> Enum.into(%{}) |> Map.put("host", self_domain)

    payload = %{
      raw: conn.assigns[:raw_body] || "",
      headers: headers,
      method: method,
      url: public_url(conn)
    }

    payload = if sign_as, do: Map.put(payload, :signAs, sign_as), else: payload

    case FedifyClient.verify(payload) do
      {:ok, %{"ok" => true} = result} ->
        {:ok, %{signer_host: signer_host(result), result: result}}

      {:ok, _} ->
        :unverified

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The URL the remote signed against, rebuilt from our public domain."
  @spec public_url(Plug.Conn.t()) :: String.t()
  def public_url(conn) do
    domain = Application.get_env(:sukhi_fedi, :domain) || conn.host
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    "https://#{domain}#{conn.request_path}#{query}"
  end

  # Host of the actor that actually signed (the key's owner; the keyId's
  # host when no owner is reported), lower-cased. nil when neither parses.
  defp signer_host(%{"owner" => owner}) when is_binary(owner), do: host(owner)
  defp signer_host(%{"keyId" => key_id}) when is_binary(key_id), do: host(key_id)
  defp signer_host(_), do: nil

  defp host(uri), do: SukhiShared.PeerCapabilities.host_of(uri)
end
