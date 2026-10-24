# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Revalidate do
  @moduledoc """
  The one place a public, rarely-changing JSON body gets its HTTP cache
  headers: a strong ETag over the encoded body, a short `max-age`, and a
  bodiless 304 when the client already holds that exact body.

  Because the tag is a hash of the bytes, nothing has to be invalidated —
  a changed directory is a changed tag. `max-age` is kept short so an edit
  shows up within a minute; `stale-while-revalidate` lets a CDN or browser
  answer instantly meanwhile.
  """

  @cache_control "public, max-age=60, stale-while-revalidate=600"

  @doc "Build the response for `body` (already a JSON string) against `req`'s `If-None-Match`."
  @spec json(map(), String.t()) :: {:ok, map()}
  def json(req, body) when is_binary(body) do
    etag = ~s("#{:crypto.hash(:sha256, body) |> Base.url_encode64(padding: false) |> binary_part(0, 22)}")

    headers = [
      {"etag", etag},
      {"cache-control", @cache_control},
      {"vary", "accept-encoding"}
    ]

    if etag in if_none_match(req) do
      {:ok, %{status: 304, body: "", headers: headers}}
    else
      {:ok, %{status: 200, body: body, headers: [{"content-type", "application/json"} | headers]}}
    end
  end

  # `If-None-Match` may list several tags and may carry the weak prefix a
  # proxy adds when it recompresses.
  defp if_none_match(req) do
    (req[:headers] || [])
    |> Enum.flat_map(fn {k, v} ->
      if String.downcase(to_string(k)) == "if-none-match",
        do: v |> to_string() |> String.split(",", trim: true),
        else: []
    end)
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
  end
end
