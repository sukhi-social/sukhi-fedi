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

  The allow-list is `SukhiFedi.HTML.Policy` (data); how it is applied is
  `SukhiFedi.HTML.Sanitizer`, an implementation chosen by
  `SukhiFedi.Backend`. This module is the one door every caller uses.
  """

  @doc """
  Sanitise an HTML string against the note/bio allow-list. Non-binary
  values (e.g. a `nil` content) pass through unchanged so this is safe to
  drop into a changeset `update_change/3`.
  """
  @spec sanitize(term()) :: term()
  def sanitize(html) when is_binary(html) do
    SukhiFedi.Backend.call(:html_sanitizer, :sanitize, [html])
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
