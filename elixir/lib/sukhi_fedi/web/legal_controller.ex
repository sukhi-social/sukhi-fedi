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

  Languages: the Japanese privacy policy follows Japan's APPI; the Korean
  follows PIPA. `?lang=ko` switches to Korean; default is Japanese (the
  instance's default UI language). Update by editing `priv/legal/*.md` and
  rebuilding.
  """
  import Plug.Conn

  @ja_privacy Path.expand("../../../priv/legal/privacy.ja.md", __DIR__)
  @ko_privacy Path.expand("../../../priv/legal/privacy.ko.md", __DIR__)
  @ja_terms Path.expand("../../../priv/legal/terms.ja.md", __DIR__)
  @ko_terms Path.expand("../../../priv/legal/terms.ko.md", __DIR__)

  @external_resource @ja_privacy
  @external_resource @ko_privacy
  @external_resource @ja_terms
  @external_resource @ko_terms

  @opts %Earmark.Options{gfm: true, breaks: false}
  @privacy_ja Earmark.as_html!(File.read!(@ja_privacy), @opts)
  @privacy_ko Earmark.as_html!(File.read!(@ko_privacy), @opts)
  @terms_ja Earmark.as_html!(File.read!(@ja_terms), @opts)
  @terms_ko Earmark.as_html!(File.read!(@ko_terms), @opts)

  # Fonts are subset to the glyphs these docs use and embedded as base64 at
  # compile time — no external request (Google Fonts would leak the reader's
  # IP, which is the wrong thing to do on a *privacy* page) and nothing extra
  # to fetch. `font-display: swap` keeps the page readable in a system font
  # if the embedded font is ignored. Only the page's own language font is
  # embedded per request.
  @biz_path Path.expand("../../../priv/legal/fonts/bizudpgothic.woff2", __DIR__)
  @nanum_path Path.expand("../../../priv/legal/fonts/nanumgothic.woff2", __DIR__)
  @external_resource @biz_path
  @external_resource @nanum_path
  @biz_b64 @biz_path |> File.read!() |> Base.encode64()
  @nanum_b64 @nanum_path |> File.read!() |> Base.encode64()

  @font_ja """
  @font-face { font-family: "BIZ UDPGothic"; font-style: normal; font-weight: 400; font-display: swap;
    src: url(data:font/woff2;base64,#{@biz_b64}) format("woff2"); }
  body { font-family: "BIZ UDPGothic", "Hiragino Sans", "Noto Sans JP", "Yu Gothic", Meiryo, sans-serif; }
  """

  @font_ko """
  @font-face { font-family: "Nanum Gothic"; font-style: normal; font-weight: 400; font-display: swap;
    src: url(data:font/woff2;base64,#{@nanum_b64}) format("woff2"); }
  body { font-family: "Nanum Gothic", "Apple SD Gothic Neo", "Noto Sans KR", "Malgun Gothic", sans-serif; }
  """

  @css """
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; line-height: 1.7; color: #222; background: #fafafa; }
  .nav, .legal, .foot { max-width: 720px; margin: 0 auto; padding-left: 1.25rem; padding-right: 1.25rem; }
  .nav { padding-top: 1.1rem; font-size: .9rem; }
  .nav a { color: #777; text-decoration: none; margin-right: 1rem; }
  .nav a:hover { text-decoration: underline; }
  .legal { padding: 1.5rem 1.25rem 3rem; }
  .legal h1 { font-size: 1.7rem; line-height: 1.3; margin: .5rem 0 1rem; }
  .legal h2 { font-size: 1.25rem; margin: 2.2rem 0 .6rem; }
  .legal h3 { font-size: 1.05rem; margin: 1.4rem 0 .4rem; }
  .legal a { color: #2563eb; text-underline-offset: 2px; word-break: break-word; }
  .legal hr { border: none; border-top: 1px solid #e3e3e3; margin: 2rem 0; }
  .legal table { border-collapse: collapse; width: 100%; margin: 1rem 0; font-size: .95rem; display: block; overflow-x: auto; }
  .legal th, .legal td { border: 1px solid #ddd; padding: .5rem .7rem; text-align: left; vertical-align: top; }
  .legal th { background: #f0f0f0; }
  .legal blockquote { margin: 1rem 0; padding: .3rem 1rem; border-left: 3px solid #cbd5e1; color: #555; background: #f5f7fa; border-radius: 0 6px 6px 0; }
  .legal pre { background: #f0f0f0; padding: 1rem; border-radius: 8px; overflow-x: auto; font-size: .85rem; line-height: 1.5; }
  .legal code { background: #f0f0f0; padding: .1rem .3rem; border-radius: 4px; font-size: .9em;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  .legal pre code { background: none; padding: 0; }
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
    .nav a, .foot, .foot a { color: #8b8f99; }
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
    case lang(conn) do
      "ko" ->
        render(conn, "ko", "개인정보 처리방침", @privacy_ko, "/privacy", {"이용약관", "/terms"}, signup?(conn))

      _ ->
        render(conn, "ja", "個人情報の取り扱いについて", @privacy_ja, "/privacy", {"利用規約", "/terms"}, signup?(conn))
    end
  end

  @spec terms(Plug.Conn.t()) :: Plug.Conn.t()
  def terms(conn) do
    case lang(conn) do
      "ko" ->
        render(conn, "ko", "이용약관", @terms_ko, "/terms", {"개인정보 처리방침", "/privacy"}, signup?(conn))

      _ ->
        render(conn, "ja", "利用規約", @terms_ja, "/terms", {"プライバシーポリシー", "/privacy"}, signup?(conn))
    end
  end

  defp lang(conn) do
    case conn.query_params do
      %{"lang" => "ko"} -> "ko"
      _ -> "ja"
    end
  end

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
  defp render(conn, lang, title, body, self_path, {cross_label, cross_path}, signup?) do
    sq = if signup?, do: "signup=true", else: nil
    lang_q = if lang == "ko", do: "lang=ko", else: nil

    {home, toggle_label, toggle_lang} =
      if lang == "ko",
        do: {"처음으로", "日本語", nil},
        else: {"トップへ", "한국어", "lang=ko"}

    toggle_href = query_url(self_path, [sq, toggle_lang])
    cross_href = query_url(cross_path, [sq, lang_q])

    cta =
      if signup? do
        label = if lang == "ko", do: "읽었어요", else: "読みました"
        ~s(<div class="cta"><a class="cta-btn" href="/signup">#{label}</a></div>)
      else
        ""
      end

    font = if lang == "ko", do: @font_ko, else: @font_ja

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
    <nav class="nav"><a href="/">← #{home}</a><a href="#{cross_href}">#{cross_label}</a><a href="#{toggle_href}">#{toggle_label}</a></nav>
    <main class="legal">#{body}</main>
    #{cta}
    <footer class="foot"><a href="#{cross_href}">#{cross_label}</a><a href="#{toggle_href}">#{toggle_label}</a><a href="/">#{home}</a></footer>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, html)
  end
end
