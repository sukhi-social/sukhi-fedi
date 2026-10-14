# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PreviewCards.Meta do
  @moduledoc """
  Reading a link-preview card out of a page's HTML: a pure function of the
  page and its URL, with no fetching (that, and the SSRF fence around it, is
  `SukhiFedi.PreviewCards`). Separate so that it can be another
  implementation — the page may be a megabyte of untrusted markup and this
  is the part that walks it.

  `parse/2` returns the card as a string-keyed map:

      %{"url", "title", "description", "image", "type", "provider_name"}

  with the rules the Elixir implementation's tests pin: `og:*` first, then
  `<title>` / `<meta name=description>`; either attribute order; HTML
  entities decoded; whitespace trimmed; empty means absent; title cut at 500
  and description at 1000 characters; `url` falls back to the page's own,
  `type` to `"link"`, `provider_name` to the page's host.

  Must not raise on any valid UTF-8 string. (The Elixir implementation does
  not raise on any binary at all, but that is not part of the contract.)
  """

  @callback parse(html :: binary(), url :: String.t()) :: map()
end
