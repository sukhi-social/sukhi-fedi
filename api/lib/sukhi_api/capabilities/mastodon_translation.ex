# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonTranslation do
  @moduledoc """
  Mastodon's status translation.

      POST /api/v1/statuses/:id/translate   scope: read:statuses   lang=ja

  Answers Mastodon's `Translation` entity (`content`, `spoiler_text`,
  `detected_source_language`, `provider`, …), so any Mastodon client can use it.
  Everything that matters — who may see the post, which engine, how much, what
  comes back — is decided in `SukhiFedi.Translate` on the gateway; this module only
  decodes the request and says the answer in HTTP (CODE_STYLE §1, "Transport").

  A refusal because someone is busy is a `429` with `retry-after`: the client waits
  that long and does not retry on its own.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc

  # An engine can take its time; the gateway's own timeout is longer than the
  # engine's (20 s), so a slow engine answers `engine_unavailable`, not a badrpc.
  @rpc_timeout 30_000

  @impl true
  def routes do
    [{:post, "/api/v1/statuses/:id/translate", &translate/1, scope: "read:statuses"}]
  end

  def translate(req) do
    %{current_account: viewer} = req[:assigns]

    case viewer do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{} = v ->
        id = req[:path_params]["id"]
        lang = params(req)["lang"]

        case GatewayRpc.run(SukhiFedi.Translate, :status, [v, id, lang], @rpc_timeout) do
          {:ok, translation} -> ok(200, translation)
          {:error, reason} -> refuse(reason)
          {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
        end
    end
  end

  defp refuse(:not_found), do: ok(404, %{error: "not_found"})
  defp refuse(:not_translatable), do: ok(403, %{error: "not_translatable"})
  defp refuse(:disabled), do: ok(503, %{error: "translation_disabled"})
  defp refuse(:unsupported_language), do: ok(422, %{error: "unsupported_language"})
  defp refuse(:too_long), do: ok(422, %{error: "too_long"})
  defp refuse(:no_key), do: ok(422, %{error: "no_key"})
  defp refuse(:key_rejected), do: ok(422, %{error: "key_rejected"})
  defp refuse(:quota), do: ok(422, %{error: "quota"})
  defp refuse(:engine_rejected), do: ok(503, %{error: "engine_unavailable"})
  defp refuse(:engine_unavailable), do: ok(503, %{error: "engine_unavailable"})

  defp refuse({:busy, seconds}) when is_integer(seconds) do
    {:ok,
     %{
       status: 429,
       body: JSON.encode!(%{error: "busy", retry_after: seconds}),
       headers: [{"content-type", "application/json"}, {"retry-after", Integer.to_string(seconds)}]
     }}
  end

  defp refuse(_), do: ok(500, %{error: "internal_error"})

  # `lang` rides in a JSON body, a form, or the query string.
  defp params(req) do
    query = URI.decode_query(req[:query] || "")
    ct = content_type(req[:headers] || [])

    body =
      cond do
        String.contains?(ct, "application/json") ->
          case JSON.decode(req[:body] || "") do
            {:ok, %{} = m} -> m
            _ -> %{}
          end

        String.contains?(ct, "application/x-www-form-urlencoded") ->
          URI.decode_query(req[:body] || "")

        true ->
          %{}
      end

    Map.merge(query, body)
  end

  defp content_type(headers) do
    Enum.find_value(headers, "", fn {k, v} ->
      if String.downcase(to_string(k)) == "content-type", do: to_string(v), else: nil
    end)
  end

  defp ok(status, body) do
    {:ok, %{status: status, body: JSON.encode!(body), headers: [{"content-type", "application/json"}]}}
  end
end
