# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HTML do
  @moduledoc """
  Allow-list HTML sanitisation for note content and account bios.

  Both local user input and federated remote HTML pass through here on
  the way *in* (Mastodon's model), so that by the time the Mastodon API
  serves `content` / `note` to the SPA's `{@html}` sinks the markup is
  already safe. `<script>`, event handlers (`onerror`/`onload`/…),
  `style`, `javascript:`/`data:` URIs, `<svg>`, `<iframe>`, `<form>` and
  anything else outside the allow-list are stripped.
  """

  @doc """
  Sanitise an HTML string against the note/bio allow-list. Non-binary
  values (e.g. a `nil` content) pass through unchanged so this is safe to
  drop into a changeset `update_change/3`.
  """
  @spec sanitize(term()) :: term()
  def sanitize(html) when is_binary(html) do
    HtmlSanitizeEx.Scrubber.scrub(html, SukhiFedi.HTML.Scrubber)
  end

  def sanitize(other), do: other

  @doc """
  Escape plaintext for safe embedding in HTML. Local note content arrives as
  plaintext (Mastodon's `status`), not markup — so escaping is the right move:
  it keeps literal `<`/`&` intact (`x<y`, `List<String>`, `<iframe>`-as-words
  all survive) while still neutralising any tag for the SPA's `{@html}` sink.
  `sanitize/1`, by contrast, *drops* tag-shaped tokens, which silently deletes
  that text — and there is no `source` column to recover it from. Use `escape/1`
  for local input, `sanitize/1` for remote HTML. Non-binary values pass through
  unchanged so this is safe in a changeset `update_change/3`.
  """
  @spec escape(term()) :: term()
  def escape(text) when is_binary(text), do: Plug.HTML.html_escape(text)
  def escape(other), do: other

  @doc """
  Reverse `escape/1` ── gives back what the author actually typed, for
  re-opening it in an edit box. `&amp;` decodes last so a literal `&lt;`
  the author typed (escaped to `&amp;lt;`) round-trips instead of
  colliding with the `<` produced by decoding `&lt;` first.
  """
  @spec unescape(term()) :: term()
  def unescape(text) when is_binary(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  def unescape(other), do: other
end

defmodule SukhiFedi.HTML.Scrubber do
  @moduledoc """
  The allow-list itself. Mirrors Mastodon's permitted tag set, plus
  `ruby`/`rt`/`rp` (Japanese ruby annotations are common here). Anything
  not explicitly allowed is dropped, including all event-handler and
  `style` attributes.
  """
  use HtmlSanitizeEx

  # Links: http(s)/mailto only — this is what blocks `javascript:` and
  # `data:` hrefs. Keep the class/rel/title that mentions, hashtags and
  # link cards rely on for styling.
  allow_tag_with_uri_attributes("a", ["href"], ["http", "https", "mailto"])
  allow_tag_with_these_attributes("a", ["name", "title", "class", "rel"])

  # Mentions and hashtags wrap their text in `<span class="...">`.
  allow_tag_with_these_attributes("span", ["class"])

  allow_tag_with_these_attributes("p", [])
  allow_tag_with_these_attributes("br", [])
  allow_tag_with_these_attributes("b", [])
  allow_tag_with_these_attributes("strong", [])
  allow_tag_with_these_attributes("i", [])
  allow_tag_with_these_attributes("em", [])
  allow_tag_with_these_attributes("u", [])
  allow_tag_with_these_attributes("s", [])
  allow_tag_with_these_attributes("del", [])
  allow_tag_with_these_attributes("ins", [])
  allow_tag_with_these_attributes("sub", [])
  allow_tag_with_these_attributes("sup", [])
  allow_tag_with_these_attributes("code", [])
  allow_tag_with_these_attributes("pre", [])
  allow_tag_with_these_attributes("blockquote", [])
  allow_tag_with_these_attributes("ul", [])
  allow_tag_with_these_attributes("ol", [])
  allow_tag_with_these_attributes("li", [])
  allow_tag_with_these_attributes("ruby", [])
  allow_tag_with_these_attributes("rt", [])
  allow_tag_with_these_attributes("rp", [])
  allow_tag_with_these_attributes("h1", [])
  allow_tag_with_these_attributes("h2", [])
  allow_tag_with_these_attributes("h3", [])
  allow_tag_with_these_attributes("h4", [])
end
