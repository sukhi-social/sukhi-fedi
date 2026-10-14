# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Backend.ContractTest do
  @moduledoc """
  What every implementation of a seam must answer, held against each of them
  (`SukhiFedi.Backend.implementations/1`). A NIF is added to that list and
  these tests run on it unchanged: the Elixir implementation is the spec, so
  where this says something, both must.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SukhiFedi.Backend

  # Valid UTF-8 built from markup-shaped pieces: malformed on purpose, never
  # invalid as text.
  @pieces ["<", ">", "&", "&amp;", "<a href=\"", "\">", "</a>", "<code>", "</code>", "<pre>", "@", "#", "@a", "#t", "@a@b.c", "x", " ",
           "日本語", "<script>", "</", "<!--", "-->", "\"", "'", "<meta property=\"og:title\" content=\"", "\u0000", "<p onclick=x>", "#1", "<b", "<svg onload=1>"]

  defp soups(n) do
    :rand.seed(:exsss, {11, 22, 33})
    for _ <- 1..n, do: Enum.map_join(1..:rand.uniform(16), "", fn _ -> Enum.random(@pieces) end)
  end

  describe "html_sanitizer" do
    for impl <- Backend.implementations(:html_sanitizer) do
      @impl_mod impl
      test "#{inspect(impl)}: drops script, handlers, javascript:/data: URIs and unlisted tags" do
        s = &@impl_mod.sanitize/1
        refute s.(~s|<p>hi <img src=x onerror=alert(1)> end</p>|) =~ "onerror"
        assert s.(~s|<svg onload=alert(1)></svg>|) == ""
        refute s.(~s|<script>alert(1)</script>ok|) =~ "<script"
        refute s.(~s|<a href="javascript:evil()">x</a>|) =~ "javascript:"
        refute s.(~s|<a href="data:text/html,xx">x</a>|) =~ "data:"
        refute s.(~s|<p style="x:y">a</p>|) =~ "style"
        assert s.("a < b & c") == "a &lt; b &amp; c"
      end

      test "#{inspect(impl)}: keeps what the policy allows" do
        s = &@impl_mod.sanitize/1
        assert s.(~s|<a href="https://ok.example/@u" class="mention" rel="nofollow">@u</a>|) ==
                 ~s|<a href="https://ok.example/@u" class="mention" rel="nofollow">@u</a>|

        assert s.(~s|<span class="h-card">t</span>|) == ~s|<span class="h-card">t</span>|
        assert s.("<ruby>漢<rt>かん</rt></ruby>") == "<ruby>漢<rt>かん</rt></ruby>"
        assert s.("<p>a <strong>b</strong> <em>c</em></p>") == "<p>a <strong>b</strong> <em>c</em></p>"
        assert s.(~s|<a href="mailto:a@b.c">m</a>|) =~ "mailto:a@b.c"
      end

      test "#{inspect(impl)}: every tag in the policy survives, with only its allowed attributes" do
        s = &@impl_mod.sanitize/1

        for {tag, spec} <- SukhiFedi.HTML.Policy.tags(), tag not in ["br"] do
          attrs = Enum.map_join(spec.attrs, " ", &~s(#{&1}="v"))
          out = s.("<#{tag} #{attrs} onclick=\"x\">t</#{tag}>")
          assert out =~ "<#{tag}", "#{tag} should be kept"
          refute out =~ "onclick", "#{tag} must not keep onclick"
          for a <- spec.attrs, do: assert(out =~ ~s(#{a}="v"), "#{tag} should keep #{a}")
        end
      end

      test "#{inspect(impl)}: settles after one more pass, and never raises on markup-shaped valid UTF-8" do
        s = &@impl_mod.sanitize/1

        # Not strictly idempotent: output that is only whitespace collapses to
        # "" on a second pass (49 of 20,000 random soups). It never grows, and
        # the third pass equals the second.
        for html <- soups(1500) do
          twice = s.(s.(html))
          assert is_binary(twice)
          assert s.(twice) == twice, "does not settle on #{inspect(html)}"
        end
      end
    end
  end

  describe "linkify_scanner" do
    for impl <- Backend.implementations(:linkify_scanner) do
      @impl_mod impl
      test "#{inspect(impl)}: tokens concatenate back to the input" do
        for html <- soups(1500) do
          out =
            @impl_mod.scan(html)
            |> Enum.map_join(fn
              {:raw, t} -> t
              {:mention, raw, _, _} -> raw
              {:hashtag, raw, _} -> raw
            end)

          assert out == html
        end
      end

      test "#{inspect(impl)}: finds mentions and hashtags" do
        assert @impl_mod.scan("hi @alice and @bob@h.example #散歩!") == [
                 {:raw, "hi "},
                 {:mention, "@alice", "alice", nil},
                 {:raw, " and "},
                 {:mention, "@bob@h.example", "bob", "h.example"},
                 {:raw, " "},
                 {:hashtag, "#散歩", "散歩"},
                 {:raw, "!"}
               ]
      end

      test "#{inspect(impl)}: leaves alone what is inside a, code, pre and tags" do
        for html <- [~s|<a href="u">@a #t</a>|, "<code>@a #t</code>", "<pre>@a #t</pre>", ~s|<p title="@a #t">x</p>|] do
          refute Enum.any?(@impl_mod.scan(html), &match?({k, _, _} when k in [:hashtag], &1))
          refute Enum.any?(@impl_mod.scan(html), &match?({:mention, _, _, _}, &1)), html
        end
      end

      test "#{inspect(impl)}: the rules" do
        scan = &@impl_mod.scan/1
        # a number alone is not a tag; a tag needs a letter somewhere
        assert scan.("#42") == [{:raw, "#42"}]
        assert scan.("#a1") == [{:hashtag, "#a1", "a1"}]
        # no empty tokens
        refute Enum.any?(scan.("@a #b x"), &(&1 == {:raw, ""}))
        assert scan.("") == []
        # @ after a word character is an e-mail tail, not a mention
        assert scan.("mail@x.com") == [{:raw, "mail@x.com"}]
        # earlier wins; at the same place the mention wins
        assert [{:mention, "@a", "a", nil}, {:raw, " "}, {:hashtag, "#b", "b"}] = scan.("@a #b")
        assert [{:hashtag, "#b", "b"}, {:raw, " "}, {:mention, "@a", "a", nil}] = scan.("#b @a")
        # an unterminated element is left alone to its end
        assert scan.("<a>@a #t") == [{:raw, "<a>@a #t"}]
      end
    end
  end

  describe "preview_meta" do
    for impl <- Backend.implementations(:preview_meta) do
      @impl_mod impl
      test "#{inspect(impl)}: og tags, either attribute order, entities, trimming" do
        html = ~s|<title>T &amp; t</title>
          <meta property="og:title" content="  The &quot;Title&quot;  ">
          <meta content="desc &lt;b&gt;" property="og:description">
          <meta name='og:image' content='https://i.example/a.png'>
          <meta property="og:site_name" content="Site">|

        card = @impl_mod.parse(html, "https://example.com/p")
        assert card["title"] == ~s|The "Title"|
        assert card["description"] == "desc <b>"
        assert card["image"] == "https://i.example/a.png"
        assert card["provider_name"] == "Site"
        assert card["type"] == "link"
        assert card["url"] == "https://example.com/p"
      end

      test "#{inspect(impl)}: falls back to <title>, meta description and the page's host; empty means absent" do
        card = @impl_mod.parse(~s|<title>Plain</title><meta name="description" content="d"><meta property="og:image" content="  ">|, "https://example.com/p")
        assert card["title"] == "Plain"
        assert card["description"] == "d"
        assert card["image"] == nil
        assert card["provider_name"] == "example.com"
      end

      test "#{inspect(impl)}: title is cut at 500 and description at 1000 characters" do
        card =
          @impl_mod.parse(
            ~s|<meta property="og:title" content="#{String.duplicate("あ", 700)}"><meta property="og:description" content="#{String.duplicate("z", 1200)}">|,
            "https://x.example/"
          )

        assert String.length(card["title"]) == 500
        assert String.length(card["description"]) == 1000
      end

      test "#{inspect(impl)}: never raises on markup-shaped valid UTF-8" do
        for html <- soups(1500), do: assert(is_map(@impl_mod.parse(html, "https://x.example/")))
      end
    end
  end

  describe "markdown" do
    for impl <- Backend.implementations(:markdown) do
      @impl_mod impl
      test "#{inspect(impl)}: gfm, and a bare newline is a <br>" do
        assert @impl_mod.render("a\nb") =~ ~r/<br\s*\/?>/
        assert @impl_mod.render("**b** and ~~s~~") =~ "<strong>b</strong>"
        assert @impl_mod.render("~~s~~") =~ "<del>s</del>"
        assert @impl_mod.render("- x\n- y") =~ "<ul>"
      end

      test "#{inspect(impl)}: inline tag-shaped text is escaped, a raw HTML block is not (that is the sanitiser's job)" do
        assert @impl_mod.render("x<y and List<String>") =~ "x&lt;y"
        assert @impl_mod.render("<script>alert(1)</script>") =~ "<script>"
      end

      test "#{inspect(impl)}: a binary, or a raise on a malformed HTML block (inherited from Earmark)" do
        # Earmark reports malformed markup on stderr; that is not what is tested.
        capture_io(:stderr, fn ->
          for text <- soups(1500) do
            try do
              assert is_binary(@impl_mod.render(text))
            rescue
              # the only raise the contract allows; see docs/native-seams.md
              CaseClauseError -> :ok
            end
          end
        end)
      end
    end
  end
end
