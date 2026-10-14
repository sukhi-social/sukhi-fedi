# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Linkify.Scanner do
  @moduledoc """
  The part of linkifying that is only text-walking: cut an HTML string into
  the stretches to leave alone and the `@mention` / `#hashtag` candidates in
  between. No lookup, no database, no escaping — so it can be a different
  implementation (a NIF) without anything else changing. Deciding what a
  mention *is* (is that a person we know?) and writing the link is
  `SukhiFedi.Linkify`'s job, on the tokens this returns.

  Tokens, in document order, which concatenated give back the input exactly:

    * `{:raw, text}` — to be left as it is: tags, the whole of an `<a>`,
      `<code>` or `<pre>` element, and text with no candidate in it.
    * `{:mention, raw, user, host}` — `raw` is the matched text (`"@a@b.c"`),
      `host` is `nil` for a local-looking `@a`.
    * `{:hashtag, raw, tag}` — `raw` is `"#tag"`.

  Rules every implementation keeps (the Elixir one's tests are the spec):
  one left-to-right pass so a candidate is never found inside text produced
  by an earlier one; nothing inside `<a>`, `<code>`, `<pre>` or inside a tag;
  a tag made only of digits is not a tag; `@` right after a word character
  or `/` is not a mention; when a mention and a hashtag both start the
  remaining text, the earlier wins and the mention wins a tie.

  Must not raise on any valid UTF-8 string. Bytes that are not UTF-8 are not
  specified (the Elixir implementation raises; see docs/native-seams.md).
  """

  @type token ::
          {:raw, binary()}
          | {:mention, raw :: binary(), user :: binary(), host :: binary() | nil}
          | {:hashtag, raw :: binary(), tag :: binary()}

  @callback scan(html :: binary()) :: [token()]
end
