# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.LegalController do
  @moduledoc """
  Serves the static legal pages — terms of service and privacy policy — in
  Japanese (default) and Korean.

  Robust by construction: the Markdown sources in `priv/legal/` are rendered
  to HTML **at compile time** and baked into the release. At runtime we only
  pick a baked body and concatenate a tiny chrome — no Markdown parsing, no
  JS, no database, no SPA — so the pages render even if everything else is
  down. A malformed source fails the build instead of reaching production.
  Fully self-contained (inline CSS, no external fonts/CDN).

  Two instances share this controller, so the documents come in *flavors*:
  the server's own (`priv/legal/*.md`, the default) and natadeco.com's
  board wording (`priv/legal/natadeco/*.md`). `LEGAL_FLAVOR=natadeco` picks
  the latter, anything else the former. Both are baked into the release —
  the env var only chooses between them at request time.

  Languages: the Japanese privacy policy follows Japan's APPI; the Korean
  follows PIPA. `?lang=ko` switches to Korean; default is Japanese (the
  instance's default UI language). Update by editing the Markdown and
  rebuilding.
  """
  import Plug.Conn

  @opts %Earmark.Options{gfm: true, breaks: false}

  # Flavor → the directory its four documents live in. Recompile when any
  # of them changes, whichever flavor set it belongs to.
  @dir Path.expand("../../../priv/legal", __DIR__)
  @flavor_dirs %{sukhi: @dir, natadeco: Path.join(@dir, "natadeco")}
  @doc_files ~w(terms.ja.md terms.ko.md privacy.ja.md privacy.ko.md)

  for {_flavor, dir} <- @flavor_dirs, file <- @doc_files do
    @external_resource Path.join(dir, file)
  end

  bake = fn dir, file ->
    # U+200B is where BudouX put a phrase break (scripts/phrase_legal.mjs);
    # Earmark would escape a literal <wbr>, so it is turned into one after.
    dir
    |> Path.join(file)
    |> File.read!()
    |> Earmark.as_html!(@opts)
    |> String.replace("\u200B", "<wbr>")
  end

  docs =
    for {flavor, dir} <- @flavor_dirs, into: %{} do
      {flavor,
       %{
         terms_ja: bake.(dir, "terms.ja.md"),
         terms_ko: bake.(dir, "terms.ko.md"),
         privacy_ja: bake.(dir, "privacy.ja.md"),
         privacy_ko: bake.(dir, "privacy.ko.md")
       }}
    end

  @docs docs

  # The closing words under every page: the parody grant, then (only where the
  # page is about open-source software) the thanks for keeping it open, then
  # the punchline. /credits is not about open-source software, so it leaves the
  # middle out.
  @closing_files ~w(licenses-end.en.md licenses-end.ja.md licenses-end.ko.md licenses-end-oss.en.md licenses-end-oss.ja.md licenses-end-last.en.md licenses-end-last.ja.md licenses-end-last.ko.md licenses-end.ja.phrased.md licenses-end-oss.ja.phrased.md licenses-end-last.ja.phrased.md)
  for file <- @closing_files, do: @external_resource(Path.join(@dir, file))

  # Japanese reads the BudouX-phrased copies (scripts/phrase_legal.mjs).
  closing = fn lang, oss? ->
    sfx = if lang == "ja", do: "ja.phrased", else: lang

    parts =
      ["licenses-end.#{sfx}.md"] ++
        if(oss?, do: ["licenses-end-oss.#{sfx}.md"], else: []) ++
        ["licenses-end-last.#{sfx}.md"]

    Enum.map_join(parts, &bake.(@dir, &1))
  end

  @closing %{en: closing.("en", true), ja: closing.("ja", true)}
  @closing_credits %{
    en: closing.("en", false),
    ja: closing.("ja", false),
    ko: closing.("ko", false)
  }

  # /licenses — thanks to the open-source projects underneath. Not a legal
  # document, so it has no flavor: one text per language (English is the
  # base; Korean readers get it too), plus the generated per-category list
  # (scripts/gen_licenses.mjs, one per language) baked in after the text.
  @licenses_files ~w(licenses.en.md licenses.ja.phrased.md licenses-list.en.html licenses-list.ja.html)
  for file <- @licenses_files, do: @external_resource(Path.join(@dir, file))

  @licenses %{
    en:
      bake.(@dir, "licenses.en.md") <>
        File.read!(Path.join(@dir, "licenses-list.en.html")) <> @closing.en,
    ja:
      bake.(@dir, "licenses.ja.phrased.md") <>
        File.read!(Path.join(@dir, "licenses-list.ja.html")) <> @closing.ja
  }

  # /licenses/rust — the Rust crates inside ojak, off the main page (see the
  # footnote there): their own text plus the generated list, then the same
  # closing words as the main page.
  @rust_files ~w(licenses-rust.en.md licenses-rust.ja.phrased.md licenses-rust-list.en.html licenses-rust-list.ja.html)
  for file <- @rust_files, do: @external_resource(Path.join(@dir, file))

  @rust %{
    en:
      bake.(@dir, "licenses-rust.en.md") <>
        File.read!(Path.join(@dir, "licenses-rust-list.en.html")) <>
        @closing.en,
    ja:
      bake.(@dir, "licenses-rust.ja.phrased.md") <>
        File.read!(Path.join(@dir, "licenses-rust-list.ja.html")) <>
        @closing.ja
  }

  # /credits — the standards sukhi implements and the projects it learns from
  # (none of them a dependency, so not on /licenses), then the same closing
  # words as the other pages. Hand-written; nothing generated.
  @credits_files ~w(credits.en.md credits.ja.md credits.ko.md)
  for file <- @credits_files, do: @external_resource(Path.join(@dir, file))

  # The logos on /credits live in priv/legal/logos/ and are embedded as data
  # URIs at compile time, like the fonts: the page makes no request of its
  # own. A `src="logos/x"` with no such file fails the build.
  @logo_files ~w(mastodon.svg misskey.svg gotosocial.png hackerspub.svg)
  for file <- @logo_files, do: @external_resource(Path.join([@dir, "logos", file]))

  embed_logos = fn html ->
    Regex.replace(~r/src="logos\/([\w.-]+)"/, html, fn _, file ->
      mime = if String.ends_with?(file, ".svg"), do: "image/svg+xml", else: "image/png"
      data = [@dir, "logos", file] |> Path.join() |> File.read!() |> Base.encode64()
      ~s(src="data:#{mime};base64,#{data}")
    end)
  end

  @credits %{
    en: embed_logos.(bake.(@dir, "credits.en.md")) <> @closing_credits.en,
    ja: embed_logos.(bake.(@dir, "credits.ja.md")) <> @closing_credits.ja,
    ko: embed_logos.(bake.(@dir, "credits.ko.md")) <> @closing_credits.ko
  }

  # /legal — the door to the four documents above. Hand-written, one short
  # list per language; no closing words (it is a signpost, not a document).
  @legal_files ~w(legal.ja.md legal.ko.md legal.en.md)
  for file <- @legal_files, do: @external_resource(Path.join(@dir, file))

  @legal %{
    ja: bake.(@dir, "legal.ja.md"),
    ko: bake.(@dir, "legal.ko.md"),
    en: bake.(@dir, "legal.en.md")
  }

  # /support — where to donate. Not a legal document either; hand-written,
  # one short text per language, no closing words.
  @support_files ~w(support.ja.md support.ko.md support.en.md)
  for file <- @support_files, do: @external_resource(Path.join(@dir, file))

  @support %{
    ja: bake.(@dir, "support.ja.md"),
    ko: bake.(@dir, "support.ko.md"),
    en: bake.(@dir, "support.en.md")
  }

  defp flavor, do: Application.get_env(:sukhi_fedi, :legal_flavor, :sukhi)
  defp docs, do: Map.fetch!(@docs, flavor())

  # Fonts are subset to the glyphs these docs use and embedded as base64 at
  # compile time — no external request (Google Fonts would leak the reader's
  # IP, which is the wrong thing to do on a *privacy* page) and nothing extra
  # to fetch. `font-display: swap` keeps the page readable in a system font
  # if the embedded font is ignored. Only the page's own language font is
  # embedded per request.
  @biz_path Path.expand("../../../priv/legal/fonts/bizudpgothic.woff2", __DIR__)
  @nanum_path Path.expand("../../../priv/legal/fonts/nanumgothic.woff2", __DIR__)
  @plex_regular_path Path.expand("../../../priv/legal/fonts/ibmplexsans-regular.woff2", __DIR__)
  @plex_bold_path Path.expand("../../../priv/legal/fonts/ibmplexsans-bold.woff2", __DIR__)
  @external_resource @plex_regular_path
  @external_resource @plex_bold_path
  @plex_regular_b64 @plex_regular_path |> File.read!() |> Base.encode64()
  @plex_bold_b64 @plex_bold_path |> File.read!() |> Base.encode64()
  @external_resource @biz_path
  @external_resource @nanum_path
  @biz_b64 @biz_path |> File.read!() |> Base.encode64()
  @nanum_b64 @nanum_path |> File.read!() |> Base.encode64()

  @font_ja """
  @font-face { font-family: "BIZ UDPGothic"; font-style: normal; font-weight: 400; font-display: swap;
    src: url(data:font/woff2;base64,#{@biz_b64}) format("woff2"); }
  body { font-family: "BIZ UDPGothic", "Hiragino Sans", "Noto Sans JP", "Yu Gothic", Meiryo, sans-serif; }
  """

  # English: IBM Plex Sans (Latin only, regular + bold). IBM's license reserves
  # the name "Plex", so these subsets carry a different internal family name
  # ("Sukhi Sans"); the copyright and license stay in the files, and the thanks
  # on the page name IBM Plex Sans as the source.
  @font_en """
  @font-face { font-family: "Sukhi Sans"; font-style: normal; font-weight: 400; font-display: swap;
    src: url(data:font/woff2;base64,#{@plex_regular_b64}) format("woff2"); }
  @font-face { font-family: "Sukhi Sans"; font-style: normal; font-weight: 700; font-display: swap;
    src: url(data:font/woff2;base64,#{@plex_bold_b64}) format("woff2"); }
  body { font-family: "Sukhi Sans", "Hiragino Sans", "Noto Sans JP", "Yu Gothic", Meiryo, system-ui, sans-serif; }
  """

  @font_ko """
  @font-face { font-family: "Nanum Gothic"; font-style: normal; font-weight: 400; font-display: swap;
    src: url(data:font/woff2;base64,#{@nanum_b64}) format("woff2"); }
  body { font-family: "Nanum Gothic", "Apple SD Gothic Neo", "Noto Sans KR", "Malgun Gothic", sans-serif; }
  """

  @css """
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  @media (prefers-reduced-motion: no-preference) { html { scroll-behavior: smooth; } }
  .legal h2[id] { scroll-margin-top: 1rem; }
  body { margin: 0; line-height: 1.7; color: #222; background: #fafafa; }
  .nav, .legal, .foot { max-width: 720px; margin: 0 auto; padding-left: 1.25rem; padding-right: 1.25rem; }
  .nav { padding-top: 1.1rem; font-size: .9rem; }
  .nav a { color: #777; text-decoration: none; margin-right: 1rem; }
  .nav a:hover { text-decoration: underline; }
  .nav a[aria-current] { color: #222; font-weight: 700; }
  .nav .lang { display: inline-block; border-left: 1px solid #ccc; padding-left: 1rem; }
  .nav .lang a:last-child { margin-right: 0; }
  .legal { padding: 1.5rem 1.25rem 3rem; }
  .legal h1 { font-size: 1.7rem; line-height: 1.3; margin: .5rem 0 1rem; }
  .legal h2 { font-size: 1.25rem; margin: 2.2rem 0 .6rem; }
  .legal h3 { font-size: 1.05rem; margin: 1.4rem 0 .4rem; }
  .legal a { color: #2563eb; text-underline-offset: 2px; word-break: break-word; }
  .legal:has(wbr) { word-break: keep-all; overflow-wrap: break-word; }
  .legal hr { border: none; border-top: 1px solid #e3e3e3; margin: 2rem 0; }
  .legal table { border-collapse: collapse; width: 100%; margin: 1rem 0; font-size: .95rem; display: block; overflow-x: auto; }
  .legal th, .legal td { border: 1px solid #ddd; padding: .5rem .7rem; text-align: left; vertical-align: top; }
  .legal th { background: #f0f0f0; }
  .legal blockquote { margin: 1rem 0; padding: .3rem 1rem; border-left: 3px solid #cbd5e1; color: #555; background: #f5f7fa; border-radius: 0 6px 6px 0; }
  .legal pre { background: #f0f0f0; padding: 1rem; border-radius: 8px; overflow-x: auto; font-size: .85rem; line-height: 1.5; }
  .legal code { background: #f0f0f0; padding: .1rem .3rem; border-radius: 4px; font-size: .9em;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  .legal pre code { background: none; padding: 0; }
  .legal img { display: block; margin: .3rem 0 .6rem; }
  .legal h2 ~ p em { display: block; margin: -.2rem 0 0; font-size: .88rem; font-style: normal; color: #777; }
  .legal hr.thin ~ p em { display: inline; margin: 0; font-size: inherit; font-style: italic; color: inherit; }
  .legal .index { margin: 1.2rem 0 2rem; border-left: 3px solid #cbd5e1; }
  .legal .index-title { margin: 0 0 .2rem; padding: 0 1rem; font-size: .85rem; letter-spacing: .08em; color: #888; }
  .legal .index a { display: block; padding: .45rem 1rem; font-size: 1.15rem; line-height: 1.4; text-decoration: none; }
  @media (min-width: 700px) { .legal .index a { padding: .3rem 1rem; } }
  .legal .index a:hover { background: #f0f0f0; }
  .legal sup.ref { margin-left: .1rem; font-size: .7em; }
  .legal sup.ref a { color: inherit; text-decoration: none; }
  .legal .notes { margin: 1.6rem 0 0; padding-top: .8rem; border-top: 1px solid #e3e3e3; font-size: .85rem; color: #777; }
  .legal .notes p { margin: 0; }
  .legal .notes a { color: inherit; }
  .legal .notes p { scroll-margin-top: 1.5rem; }
  .legal .notes p:target { padding: .5rem .7rem; margin: -.5rem -.7rem; outline: 2px dotted #2563eb; outline-offset: 2px; border-radius: 4px; color: #333; }
  .deps summary .n { color: #999; font-size: .85em; font-weight: 400; }
  .deps details { margin: .35rem 0; }
  .deps summary { cursor: pointer; padding: .25rem 0; font-size: 1.05rem; }
  .deps .names { list-style: none; margin: .3rem 0 .9rem; padding: 0 0 0 .9rem; columns: 2 19rem; column-gap: 1.5rem; font-size: .88rem; line-height: 1.55; word-break: break-word; }
  .deps .names li { break-inside: avoid; padding: .15rem 0; }
  .deps .names a { color: inherit; }
  .deps .v { color: #888; }
  .deps .l { margin-left: .35rem; padding: 0 .35rem; border: 1px solid #ddd; border-radius: 4px; font-size: .72rem; color: #888; white-space: nowrap; }
  .deps a.w { margin-left: .35rem; font-size: .78rem; color: #888; }
  .deps a.l { text-decoration: none; }
  .deps a.l:hover { color: #2563eb; border-color: #2563eb; }
  .deps .c a { color: inherit; }
  .deps .c { display: block; font-size: .8rem; color: #777; }
  .foot { padding: 1.5rem 1.25rem 3rem; border-top: 1px solid #e3e3e3; font-size: .9rem; color: #888; }
  .foot a { color: #666; margin-right: .6rem; }
  .cta { max-width: 720px; margin: 0 auto; padding: .5rem 1.25rem 1rem; text-align: center; }
  .cta-btn { display: inline-block; padding: .65rem 1.9rem; border: 1px solid #b6b4a4; border-radius: 8px;
    color: #222; text-decoration: none; font-size: 1rem; }
  .cta-btn:hover { background: #f0f0f0; }
  @media (prefers-color-scheme: dark) {
    body { color: #dcdde0; background: #16181c; }
    .legal a { color: #7aa2f7; }
    .legal hr, .foot { border-color: #2a2e37; }
    .legal th, .legal td { border-color: #333; }
    .legal th { background: #20242c; }
    .legal blockquote { color: #aab; background: #1c2027; border-left-color: #3a4150; }
    .legal pre, .legal code { background: #20242c; }
    .legal .index { border-left-color: #3a4150; }
    .legal .index-title { color: #9aa0ab; }
    .legal .index a:hover { background: #20242c; }
    .legal h2 ~ p em, .deps .names, .deps .c, .legal .notes { color: #9aa0ab; }
    .legal .notes { border-top-color: #2a2e37; }
    .legal .notes p:target { outline-color: #7aa2f7; color: #dcdde0; }
    .deps .l { border-color: #333; }
    .deps a.l:hover { color: #7aa2f7; border-color: #7aa2f7; }
    .nav a, .foot, .foot a { color: #8b8f99; }
    .nav a[aria-current] { color: #e6e6e6; }
    .nav .lang { border-color: #2a2e37; }
    .cta-btn { color: #dcdde0; border-color: #3a4150; }
    .cta-btn:hover { background: #20242c; }
  }
  """

  # `?signup=true` ── 加入の途中から見に来た人。一番下に「読みました」を
  # 出して /signup に戻れるようにする(誘い→読む→戻る、の流れ)。規約と
  # プライバシーは行き来できるので、両方が signup を受ける。
  defp signup?(conn), do: match?(%{"signup" => "true"}, conn.query_params)

  @spec privacy(Plug.Conn.t()) :: Plug.Conn.t()
  def privacy(conn) do
    body = docs()

    case lang(conn) do
      "ko" ->
        render(
          conn,
          "ko",
          "개인정보 처리방침",
          body.privacy_ko,
          "/privacy",
          {"이용약관", "/terms"},
          signup?(conn)
        )

      _ ->
        render(
          conn,
          "ja",
          "個人情報の取り扱いについて",
          body.privacy_ja,
          "/privacy",
          {"利用規約", "/terms"},
          signup?(conn)
        )
    end
  end

  @spec terms(Plug.Conn.t()) :: Plug.Conn.t()
  def terms(conn) do
    body = docs()

    case lang(conn) do
      "ko" ->
        render(
          conn,
          "ko",
          "이용약관",
          body.terms_ko,
          "/terms",
          {"개인정보 처리방침", "/privacy"},
          signup?(conn)
        )

      _ ->
        render(
          conn,
          "ja",
          "利用規約",
          body.terms_ja,
          "/terms",
          {"プライバシーポリシー", "/privacy"},
          signup?(conn)
        )
    end
  end

  @spec licenses(Plug.Conn.t()) :: Plug.Conn.t()
  def licenses(conn) do
    case conn.query_params do
      %{"lang" => "ja"} ->
        render(
          conn,
          "ja",
          "ライセンス",
          @licenses.ja,
          "/licenses",
          {"利用規約", "/terms"},
          false,
          {"English", nil}
        )

      _ ->
        render(
          conn,
          "en",
          "Licenses",
          @licenses.en,
          "/licenses",
          {"Terms", "/terms"},
          false,
          {"日本語", "lang=ja"}
        )
    end
  end

  @spec credits(Plug.Conn.t()) :: Plug.Conn.t()
  def credits(conn) do
    case conn.query_params do
      %{"lang" => "ja"} ->
        render(
          conn,
          "ja",
          "クレジット",
          @credits.ja,
          "/credits",
          {"ライセンス", "/licenses?lang=ja"},
          false,
          [{"English", nil}, {"한국어", "lang=ko"}]
        )

      %{"lang" => "ko"} ->
        render(
          conn,
          "ko",
          "크레딧",
          @credits.ko,
          "/credits",
          {"라이선스", "/licenses"},
          false,
          [{"English", nil}, {"日本語", "lang=ja"}]
        )

      _ ->
        render(
          conn,
          "en",
          "Credits",
          @credits.en,
          "/credits",
          {"Licenses", "/licenses"},
          false,
          [{"日本語", "lang=ja"}, {"한국어", "lang=ko"}]
        )
    end
  end

  @spec legal(Plug.Conn.t()) :: Plug.Conn.t()
  def legal(conn) do
    case conn.query_params do
      %{"lang" => "ko"} ->
        render(
          conn,
          "ko",
          "약관 및 라이선스",
          @legal.ko,
          "/legal",
          {"이용약관", "/terms"},
          false,
          [{"日本語", nil}, {"English", "lang=en"}]
        )

      %{"lang" => "en"} ->
        render(
          conn,
          "en",
          "Legal",
          @legal.en,
          "/legal",
          {"Terms", "/terms"},
          false,
          [{"日本語", nil}, {"한국어", "lang=ko"}]
        )

      _ ->
        render(
          conn,
          "ja",
          "規約・ライセンス",
          @legal.ja,
          "/legal",
          {"利用規約", "/terms"},
          false,
          [{"한국어", "lang=ko"}, {"English", "lang=en"}]
        )
    end
  end

  @spec support(Plug.Conn.t()) :: Plug.Conn.t()
  def support(conn) do
    case conn.query_params do
      %{"lang" => "ko"} ->
        render(
          conn,
          "ko",
          "후원",
          @support.ko,
          "/support",
          {"약관 및 라이선스", "/legal"},
          false,
          [{"日本語", nil}, {"English", "lang=en"}]
        )

      %{"lang" => "en"} ->
        render(
          conn,
          "en",
          "Support",
          @support.en,
          "/support",
          {"Legal", "/legal"},
          false,
          [{"日本語", nil}, {"한국어", "lang=ko"}]
        )

      _ ->
        render(
          conn,
          "ja",
          "サポート",
          @support.ja,
          "/support",
          {"規約・ライセンス", "/legal"},
          false,
          [{"한국어", "lang=ko"}, {"English", "lang=en"}]
        )
    end
  end

  @spec rust(Plug.Conn.t()) :: Plug.Conn.t()
  def rust(conn) do
    case conn.query_params do
      %{"lang" => "ja"} ->
        render(
          conn,
          "ja",
          "ojak の中の Rust クレート",
          @rust.ja,
          "/licenses/rust",
          {"ライセンス", "/licenses?lang=ja"},
          false,
          {"English", nil}
        )

      _ ->
        render(
          conn,
          "en",
          "Rust crates inside ojak",
          @rust.en,
          "/licenses/rust",
          {"Licenses", "/licenses"},
          false,
          {"日本語", "lang=ja"}
        )
    end
  end

  defp lang(conn) do
    case conn.query_params do
      %{"lang" => "ko"} -> "ko"
      _ -> "ja"
    end
  end

  # {path, label, query} for the documents, in the page's language. Terms
  # and privacy are ja ⇄ ko; licenses are en ⇄ ja (Korean readers get en);
  # credits are all three.
  defp doc_nav("ko"),
    do: [
      {"/terms", "이용약관", "lang=ko"},
      {"/privacy", "개인정보 처리방침", "lang=ko"},
      {"/licenses", "라이선스", nil},
      {"/credits", "크레딧", "lang=ko"},
      {"/legal", "약관 및 라이선스", "lang=ko"},
      {"/support", "후원", "lang=ko"}
    ]

  defp doc_nav("en"),
    do: [
      {"/terms", "Terms", nil},
      {"/privacy", "Privacy Policy", nil},
      {"/licenses", "Licenses", nil},
      {"/credits", "Credits", nil},
      {"/legal", "Legal", "lang=en"},
      {"/support", "Support", "lang=en"}
    ]

  defp doc_nav(_ja),
    do: [
      {"/terms", "利用規約", nil},
      {"/privacy", "プライバシーポリシー", nil},
      {"/licenses", "ライセンス", "lang=ja"},
      {"/credits", "クレジット", "lang=ja"},
      {"/legal", "規約・ライセンス", nil},
      {"/support", "サポート", nil}
    ]

  # Join a path with the non-nil query parts, in order. [] -> bare path.
  defp query_url(path, parts) do
    case Enum.reject(parts, &is_nil/1) do
      [] -> path
      qs -> path <> "?" <> Enum.join(qs, "&")
    end
  end

  # Build the self-contained page at runtime: pick the baked body, wrap a
  # tiny chrome (home, the other doc in the same language, a language
  # toggle). Pure string work — cannot fail. `signup?` adds a "read it"
  # button at the bottom that returns to /signup, and keeps the signup flag
  # on the cross-link and the language toggle so neither loses the way back.
  #
  # `toggle` is `{label, query}` for the language link; terms/privacy leave
  # it out (ja ⇄ ko), /licenses passes its own (en ⇄ ja); /credits passes a list
  # (en, ja, ko: each page links the other two).
  defp render(conn, lang, title, body, self_path, cross, signup?, toggle \\ nil)

  defp render(conn, lang, title, body, self_path, {cross_label, cross_path}, signup?, toggle) do
    sq = if signup?, do: "signup=true", else: nil
    lang_q = if lang == "ko", do: "lang=ko", else: nil

    home =
      case lang do
        "ko" -> "처음으로"
        "en" -> "Home"
        _ -> "トップへ"
      end

    toggles =
      case toggle do
        nil when lang == "ko" -> [{"日本語", nil}]
        nil -> [{"한국어", "lang=ko"}]
        {_, _} = one -> [one]
        many -> many
      end

    toggle_links =
      Enum.map_join(toggles, fn {label, q} ->
        ~s(<a href="#{query_url(self_path, [sq, q])}">#{label}</a>)
      end)

    # The four documents, on top of every one of them; the one you are on is
    # marked (the Rust page counts as Licenses).
    doc_links =
      Enum.map_join(doc_nav(lang), fn {path, label, q} ->
        current = if String.starts_with?(self_path, path), do: ~s( aria-current="page"), else: ""
        ~s(<a href="#{query_url(path, [sq, q])}"#{current}>#{label}</a>)
      end)

    cross_href = query_url(cross_path, [sq, lang_q])

    cta =
      if signup? do
        label = if lang == "ko", do: "읽었어요", else: "読みました"
        ~s(<div class="cta"><a class="cta-btn" href="/signup">#{label}</a></div>)
      else
        ""
      end

    font =
      case lang do
        "ko" -> @font_ko
        "en" -> @font_en
        _ -> @font_ja
      end

    html = """
    <!doctype html>
    <html lang="#{lang}">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="index,follow">
    <title>#{title} · #{SukhiFedi.Config.domain!()}</title>
    <style>#{@css}#{font}</style>
    </head>
    <body>
    <nav class="nav"><a href="/">← #{home}</a>#{doc_links}<span class="lang">#{toggle_links}</span></nav>
    <main class="legal">#{body}</main>
    #{cta}
    <footer class="foot"><a href="#{cross_href}">#{cross_label}</a>#{toggle_links}<a href="/">#{home}</a></footer>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, html)
  end
end
