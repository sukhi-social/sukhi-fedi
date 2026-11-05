# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Translate.LibreTranslate do
  @moduledoc """
  The server's own translator: a LibreTranslate instance the operator runs
  (`LIBRETRANSLATE_URL`, optionally `LIBRETRANSLATE_API_KEY`). Text goes to it and
  to nothing else; it is the engine for people who brought no key of their own.

  The URL is the operator's own setting, not anything a remote party or a user can
  influence, so it does not pass `UrlGuard` (it may well be a private address on the
  compose network — that is the point). A request carries only the text, the
  languages and the format; redirects are not followed.

  `translate/3` is the only function the context calls. It answers
  `{:ok, %{texts: [String.t()], detected: String.t() | nil}}`, or `{:error, reason}` with
  one of `:unsupported_language`, `:busy`, `:engine_rejected`, `:engine_unavailable`.
  """

  @timeout 20_000

  @spec configured?() :: boolean()
  def configured?, do: is_binary(url())

  @spec translate([String.t()], String.t() | nil, String.t()) ::
          {:ok, %{texts: [String.t()], detected: String.t() | nil}} | {:error, atom()}
  def translate(texts, source, target) when is_list(texts) and is_binary(target) do
    body =
      %{q: texts, source: source || "auto", target: target, format: "html"}
      |> put_api_key(api_key())

    opts =
      [json: body, receive_timeout: @timeout, retry: false, redirect: false]
      |> Keyword.merge(Application.get_env(:sukhi_fedi, :translate_req_options, []))

    case Req.post(url() <> "/translate", opts) do
      {:ok, %Req.Response{status: 200, body: %{"translatedText" => out} = body}} ->
        {:ok, %{texts: List.wrap(out), detected: detected(body)}}

      {:ok, %Req.Response{status: 400}} ->
        {:error, :unsupported_language}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :busy}

      {:ok, %Req.Response{status: s}} when s in [401, 403] ->
        {:error, :engine_rejected}

      {:ok, %Req.Response{}} ->
        {:error, :engine_unavailable}

      {:error, _} ->
        {:error, :engine_unavailable}
    end
  end

  defp put_api_key(body, nil), do: body
  defp put_api_key(body, key), do: Map.put(body, :api_key, key)

  # One text answers a map, several answer a list of maps (LibreTranslate ≥ 1.5).
  defp detected(%{"detectedLanguage" => %{"language" => l}}) when is_binary(l), do: l
  defp detected(%{"detectedLanguage" => [%{"language" => l} | _]}) when is_binary(l), do: l
  defp detected(_), do: nil

  defp url do
    case Application.get_env(:sukhi_fedi, :libretranslate_url) do
      u when is_binary(u) and u != "" -> String.trim_trailing(u, "/")
      _ -> nil
    end
  end

  defp api_key do
    case Application.get_env(:sukhi_fedi, :libretranslate_api_key) do
      k when is_binary(k) and k != "" -> k
      _ -> nil
    end
  end
end
