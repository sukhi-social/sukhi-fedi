# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.ExtractContentTest do
  use ExUnit.Case, async: true

  # Pure function, no DB — but the repo's local runner is
  # `make test-pgrust` (`--only integration`), so tag it to ride along.
  @moduletag :integration

  alias SukhiFedi.AP.Instructions.Extract

  describe "content_with_title/1" do
    test "an Article folds its name in as a leading <h2>" do
      obj = %{"type" => "Article", "name" => "On calm timelines", "content" => "<p>body</p>"}
      assert Extract.content_with_title(obj) == "<h2>On calm timelines</h2><p>body</p>"
    end

    test "the title is HTML-escaped (it is plain text per AS2)" do
      obj = %{"type" => "Article", "name" => "a < b & \"c\"", "content" => "<p>x</p>"}
      assert Extract.content_with_title(obj) == "<h2>a &lt; b &amp; &quot;c&quot;</h2><p>x</p>"
    end

    test "a blank or whitespace-only name adds no heading" do
      assert Extract.content_with_title(%{"type" => "Article", "name" => "  ", "content" => "<p>x</p>"}) ==
               "<p>x</p>"
    end

    test "a Note is left untouched (no title to fold)" do
      assert Extract.content_with_title(%{"type" => "Note", "content" => "<p>hi</p>"}) == "<p>hi</p>"
    end

    test "a titleless object with missing content yields an empty string" do
      assert Extract.content_with_title(%{"type" => "Note"}) == ""
    end
  end

  describe "article_title/1" do
    test "an Article returns its trimmed name" do
      assert Extract.article_title(%{"type" => "Article", "name" => "  Calm timelines  "}) ==
               "Calm timelines"
    end

    test "a blank name is nil" do
      assert Extract.article_title(%{"type" => "Article", "name" => "   "}) == nil
    end

    test "a Note has no title" do
      assert Extract.article_title(%{"type" => "Note", "name" => "ignored"}) == nil
      assert Extract.article_title(%{"type" => "Note", "content" => "hi"}) == nil
    end
  end
end
