# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Markdown do
  @moduledoc """
  Render what a local author typed into the HTML their readers get.

  `breaks: true` is the point of this for most posts: a bare newline
  becomes a `<br>`. Without it a line break the author typed is just
  whitespace inside `<p>`, and HTML folds it into a space — which is
  what sukhi did to every multi-line post until now, here and on every
  server it federated to.

  **Earmark alone is not safe.** It escapes inline tag-shaped text
  (`x<y`, `List<String>` survive as characters, which is what we want),
  but a line that *starts* a block of raw HTML is passed straight
  through — `<script>alert(1)</script>` comes out of `as_html!/2` intact.
  Only the allow-list scrubber that follows removes it. So the two steps
  live in this one function and there is no way to call the first
  without the second.

  Local input only. Remote notes arrive as HTML already and go through
  `SukhiFedi.HTML.sanitize/1` on the way in; running Markdown over
  someone else's markup would change their words.
  """

  @doc """
  Markdown → sanitised HTML. Non-binary input (a `nil` body) passes
  through unchanged, so this is safe to drop into a changeset.
  """
  @spec to_html(term()) :: term()
  def to_html(text, lookup \\ &SukhiFedi.Linkify.known_account/1)

  def to_html(text, lookup) when is_binary(text) do
    text
    |> render()
    # `@だれか` と `#なにか` を、ここでリンクにする。Markdown のあと、
    # scrubber の前 ── 出すのはこちらの組んだ小さな HTML なので、その
    # まま allow-list を通して確かめてもらえる。
    |> SukhiFedi.Linkify.run(lookup)
    |> SukhiFedi.HTML.sanitize()
    |> String.trim()
  end

  def to_html(other, _lookup), do: other

  # Earmark raises a CaseClauseError on some malformed raw-HTML blocks (an
  # unterminated attribute quote, say). A post must not 500 for that: fall
  # back to the author's text, escaped, as plain paragraphs. Escaped means
  # nothing here is markup, so the sanitiser after it has nothing to find.
  # The one rescue lives here, not in each backend.
  defp render(text) do
    SukhiFedi.Backend.call(:markdown, :render, [text])
  rescue
    CaseClauseError -> plain(text)
  end

  defp plain(text) do
    text
    |> String.split(~r/\R{2,}/)
    |> Enum.map_join("\n", fn para ->
      escaped = para |> String.trim() |> Plug.HTML.html_escape() |> String.replace(~r/\R/, "<br>\n")
      "<p>" <> escaped <> "</p>"
    end)
  end
end
