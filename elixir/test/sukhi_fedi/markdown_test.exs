# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.MarkdownTest do
  use ExUnit.Case, async: true

  # Pure, no DB; the runner filters to `--only integration`.
  @moduletag :integration

  import Ecto.Changeset, only: [get_change: 2]
  alias SukhiFedi.Markdown
  alias SukhiFedi.Schema.Note

  describe "to_html/1" do
    test "a line break the author typed stays a line break" do
      # The whole reason this exists. A bare newline inside <p> is just
      # whitespace to HTML, so every multi-line post here read as one
      # run-on paragraph — here and on every server it federated to.
      assert Markdown.to_html("ひとつめ\nふたつめ") =~ "<br"
    end

    test "a blank line still starts a new paragraph" do
      html = Markdown.to_html("ひとつめ\n\nふたつめ")
      assert length(String.split(html, "<p>")) == 3
    end

    test "the usual marks come through" do
      html = Markdown.to_html("**ふとじ** と `コード` と [link](https://example.com)")
      assert html =~ "<strong>ふとじ</strong>"
      assert html =~ "<code>コード</code>"
      assert html =~ ~s|<a href="https://example.com">link</a>|
    end

    test "lists come through" do
      html = Markdown.to_html("- ひとつ\n- ふたつ")
      assert html =~ "<ul>"
      assert length(String.split(html, "<li>")) == 3
    end

    # ── ここから、危ないほう ──────────────────────────────────────────
    #
    # Earmark **alone** is not safe: it escapes inline tag-shaped text, but
    # a line that starts a block of raw HTML passes straight through. These
    # only hold because `to_html/1` runs the scrubber after it. If someone
    # ever splits those two steps apart, these are the tests that fall over.

    test "a script tag does not survive (earmark alone would let it through)" do
      # Proof that the danger is real, not hypothetical:
      assert Earmark.as_html!("<script>alert(1)</script>") =~ "<script"
      # ...and that we don't ship it.
      refute Markdown.to_html("<script>alert(1)</script>") =~ "<script"
    end

    test "a javascript: link loses its href" do
      html = Markdown.to_html("[わるいの](javascript:alert(1))")
      refute html =~ "javascript:"
    end

    test "an onerror handler does not survive" do
      refute Markdown.to_html(~s|<img src=x onerror="alert(1)">|) =~ "onerror"
    end

    test "tag-shaped text a person actually typed survives as text" do
      # `escape/1` was chosen over `sanitize/1` for local input precisely so
      # these don't silently vanish. Markdown must not undo that.
      html = Markdown.to_html("x<y と List<String> の話")
      assert html =~ "x&lt;y"
      assert html =~ "List&lt;String&gt;"
    end

    test "nil passes through, so a changeset can hand it straight over" do
      assert Markdown.to_html(nil) == nil
    end
  end

  describe "the note changeset" do
    test "a local note gets its rendered form" do
      cs = Note.changeset(%Note{}, %{content: "ひとつめ\nふたつめ", account_id: 1})
      assert get_change(cs, :content_html) =~ "<br"
    end

    test "and keeps the source the author typed" do
      # `content` is what search, the keyword filters and an edit read.
      cs = Note.changeset(%Note{}, %{content: "**ふとじ**", account_id: 1})
      assert get_change(cs, :content) == "**ふとじ**"
    end

    test "a remote note gets none — that is someone else's markup" do
      cs =
        Note.changeset(%Note{}, %{
          content: "<p>hi</p>",
          account_id: 1,
          ap_id: "https://remote.example/notes/1"
        })

      assert get_change(cs, :content_html) == nil
    end
  end

  describe "html/1 — what a reader (or another server) gets" do
    test "the rendered form, when there is one" do
      assert Note.html(%{content: "**a**", content_html: "<p><strong>a</strong></p>"}) ==
               "<p><strong>a</strong></p>"
    end

    test "falls back to content for a remote note (already HTML)" do
      assert Note.html(%{content: "<p>hi</p>", content_html: nil}) == "<p>hi</p>"
    end

    test "falls back for a local note written before the column existed" do
      # Serving these exactly as before is the point of the fallback —
      # nothing was rewritten, so nothing should read differently.
      assert Note.html(%{content: "old plaintext", content_html: nil}) == "old plaintext"
    end

    test "an empty rendered form is not an answer" do
      assert Note.html(%{content: "hi", content_html: ""}) == "hi"
    end
  end
end
