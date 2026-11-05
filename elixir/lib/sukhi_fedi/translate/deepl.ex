# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Translate.DeepL do
  @moduledoc """
  DeepL's API, with the person's own key (bring-your-own-key).

  There are exactly two places this module speaks to, and both are written here:
  `api-free.deepl.com` for a Free-plan key (the key ends in `:fx`) and
  `api.deepl.com` for a Pro key. Nothing in a request can change where it goes — no
  user- or remote-supplied URL, no redirects — so this is an egress with a fixed
  address (CODE_STYLE §6) and needs no `UrlGuard`.

  The key travels in one header, `Authorization: DeepL-Auth-Key …`, and nowhere
  else: not in the body, not in a log line, not in an error term. A failed call
  answers one of `:key_rejected`, `:quota`, `:busy`, `:unsupported_language`,
  `:engine_unavailable` — atoms, never the response.
  """

  @timeout 20_000

  @spec translate([String.t()], String.t() | nil, String.t(), String.t()) ::
          {:ok, %{texts: [String.t()], detected: String.t() | nil}} | {:error, atom()}
  def translate(texts, source, target, key) when is_list(texts) and is_binary(key) do
    body =
      %{text: texts, target_lang: target_code(target), tag_handling: "html"}
      |> then(fn b -> if source, do: Map.put(b, :source_lang, String.upcase(source)), else: b end)

    opts =
      [
        json: body,
        headers: [{"authorization", "DeepL-Auth-Key " <> key}],
        receive_timeout: @timeout,
        retry: false,
        redirect: false
      ]
      |> Keyword.merge(Application.get_env(:sukhi_fedi, :translate_req_options, []))

    case Req.post(base(key) <> "/v2/translate", opts) do
      {:ok, %Req.Response{status: 200, body: %{"translations" => [_ | _] = ts}}} ->
        {:ok, %{texts: Enum.map(ts, & &1["text"]), detected: detected(ts)}}

      {:ok, %Req.Response{status: 403}} -> {:error, :key_rejected}
      {:ok, %Req.Response{status: 456}} -> {:error, :quota}
      {:ok, %Req.Response{status: 429}} -> {:error, :busy}
      {:ok, %Req.Response{status: 400}} -> {:error, :unsupported_language}
      {:ok, %Req.Response{}} -> {:error, :engine_unavailable}
      {:error, _} -> {:error, :engine_unavailable}
    end
  end

  defp base(key) do
    if String.ends_with?(key, ":fx"), do: "https://api-free.deepl.com", else: "https://api.deepl.com"
  end

  # DeepL asks for a regional English target; everything else is the code, upper-cased.
  defp target_code("en"), do: "EN-US"
  defp target_code(code), do: String.upcase(code)

  defp detected([%{"detected_source_language" => l} | _]) when is_binary(l), do: String.downcase(l)
  defp detected(_), do: nil
end
