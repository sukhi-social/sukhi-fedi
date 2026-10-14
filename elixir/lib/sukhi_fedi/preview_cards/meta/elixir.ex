# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PreviewCards.Meta.Elixir do
  @moduledoc """
  The parser that runs today: regexes over the raw HTML, no HTML-parser
  dependency. The behaviour is `SukhiFedi.PreviewCards.Meta`.
  """

  @behaviour SukhiFedi.PreviewCards.Meta

  @impl true
  def parse(html, url) when is_binary(html) do
    %{
      "url" => og(html, "og:url") || url,
      "title" => trunc_at(og(html, "og:title") || title_tag(html) || "", 500),
      "description" => trunc_at(og(html, "og:description") || meta_name(html, "description") || "", 1000),
      "image" => og(html, "og:image"),
      "type" => og(html, "og:type") || "link",
      "provider_name" => og(html, "og:site_name") || URI.parse(url).host || ""
    }
  end

  # `<meta property="og:x" content="...">` — try both attribute orders.
  defp og(html, prop) do
    meta_attr(html, "property", prop) || meta_attr(html, "name", prop)
  end

  defp meta_name(html, name), do: meta_attr(html, "name", name)

  defp meta_attr(html, key, val) do
    forward =
      Regex.run(
        ~r/<meta[^>]+#{key}=["']#{Regex.escape(val)}["'][^>]+content=["']([^"']*)["']/i,
        html
      )

    backward =
      Regex.run(
        ~r/<meta[^>]+content=["']([^"']*)["'][^>]+#{key}=["']#{Regex.escape(val)}["']/i,
        html
      )

    case forward || backward do
      [_, content] -> content |> unescape() |> String.trim() |> presence()
      _ -> nil
    end
  end

  defp title_tag(html) do
    case Regex.run(~r/<title[^>]*>([^<]*)<\/title>/i, html) do
      [_, t] -> t |> unescape() |> String.trim() |> presence()
      _ -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(s), do: s

  defp trunc_at(s, n) when byte_size(s) <= n, do: s
  defp trunc_at(s, n), do: String.slice(s, 0, n)

  defp unescape(s) do
    s
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
  end
end
