# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.LegalControllerTest do
  use ExUnit.Case, async: true

  # Picked up by the `--only integration` runner; no DB needed.
  @moduletag :integration

  import Plug.Test

  alias SukhiFedi.Web.LegalController

  defp get(path), do: conn(:get, path) |> Plug.Conn.fetch_query_params()

  test "/privacy defaults to Japanese (APPI), self-contained HTML, no JS" do
    conn = get("/privacy") |> LegalController.privacy()

    assert conn.status == 200
    assert {"content-type", "text/html; charset=utf-8"} in conn.resp_headers
    assert conn.resp_body =~ "個人情報の取り扱いについて"
    assert conn.resp_body =~ "個人情報保護法"
    assert conn.resp_body =~ "<table>"
    refute conn.resp_body =~ "<script"
  end

  test "Japanese page embeds BIZ UDPGothic, Korean embeds Nanum, no external font request" do
    ja = get("/privacy") |> LegalController.privacy() |> Map.get(:resp_body)
    ko = get("/privacy?lang=ko") |> LegalController.privacy() |> Map.get(:resp_body)

    # ja page: BIZ font embedded, Nanum not present
    assert ja =~ ~s("BIZ UDPGothic")
    assert ja =~ "@font-face"
    assert ja =~ "font/woff2;base64,"
    refute ja =~ "Nanum"

    # ko page: Nanum embedded, BIZ not present
    assert ko =~ ~s("Nanum Gothic")
    refute ko =~ "BIZ UDPGothic"

    # never an external font request (privacy page must not call Google)
    refute ja =~ "googleapis"
    refute ja =~ "gstatic"
    refute ko =~ "gstatic"
  end

  test "/privacy?lang=ko serves the Korean (PIPA) version" do
    conn = get("/privacy?lang=ko") |> LegalController.privacy()

    assert conn.status == 200
    assert conn.resp_body =~ "개인정보 처리방침"
    refute conn.resp_body =~ "<script"
  end

  test "/terms defaults to Japanese and links to the privacy page" do
    conn = get("/terms") |> LegalController.terms()

    assert conn.status == 200
    assert conn.resp_body =~ "ようこそ"
    assert conn.resp_body =~ ~s(href="/privacy")
    refute conn.resp_body =~ "<script"
  end

  test "the default flavor is the server's own, not natadeco's board wording" do
    body = get("/terms") |> LegalController.terms() |> Map.get(:resp_body)

    assert body =~ "f3liz-dev@proton.me"
    refute body =~ "natadeco.com"
    refute body =~ "掲示板"
  end

  test "LEGAL_FLAVOR=natadeco serves the board wording and contact" do
    previous = Application.get_env(:sukhi_fedi, :legal_flavor)
    Application.put_env(:sukhi_fedi, :legal_flavor, :natadeco)
    on_exit(fn -> Application.put_env(:sukhi_fedi, :legal_flavor, previous) end)

    terms = get("/terms") |> LegalController.terms() |> Map.get(:resp_body)
    assert terms =~ "掲示板"
    assert terms =~ "admin@natadeco.com"
    refute terms =~ "f3liz-dev@proton.me"

    privacy = get("/privacy") |> LegalController.privacy() |> Map.get(:resp_body)
    assert privacy =~ "admin@natadeco.com"
  end

  test "/licenses is English by default, self-contained, with the list closed" do
    conn = get("/licenses") |> LegalController.licenses()

    assert conn.status == 200
    assert conn.resp_body =~ "<h1>\nLicenses</h1>"
    assert conn.resp_body =~ "Thank you for maintaining this project as open source"
    assert conn.resp_body =~ "AS-IS “Thank you!”"
    assert conn.resp_body =~ "scroll-behavior: smooth"
    assert conn.resp_body =~ ~s(<p class="index-title">Index</p>)
    assert conn.resp_body =~ ~s(<a href="#all-dependencies">)
    assert conn.resp_body =~ ~s(<h2 id="all-dependencies">)
    assert conn.resp_body =~ ~s(<details id="deps-languages"><summary>Languages)
    refute conn.resp_body =~ "<details open"
    refute conn.resp_body =~ "<script"
    # English embeds its own Latin subset (IBM Plex Sans, renamed) — and still
    # no external font request, nor the Japanese font
    assert conn.resp_body =~ ~s(font-family: "Sukhi Sans")
    assert conn.resp_body =~ "font/woff2;base64,"
    refute conn.resp_body =~ ~s(font-family: "BIZ UDPGothic")
    refute conn.resp_body =~ "fonts.googleapis"
    refute conn.resp_body =~ "fonts.gstatic"
  end

  test "/licenses?lang=ja serves the Japanese words and links back to English" do
    conn = get("/licenses?lang=ja") |> LegalController.licenses()

    assert conn.status == 200
    assert conn.resp_body =~ "ささやかな感謝を"
    assert conn.resp_body =~ "そのままの、感謝を"
    assert conn.resp_body =~ "<strong>\nこのソフトウェア" or conn.resp_body =~ "<strong>このソフトウェア"
    refute conn.resp_body =~ "<em>このソフトウェア"
    assert conn.resp_body =~ "<summary>言語"
    assert conn.resp_body =~ ~s(href="/licenses")
    assert conn.resp_body =~ "font/woff2;base64,"
  end

  test "the Rust crates have their own page, categories closed like the main list" do
    conn = get("/licenses/rust") |> LegalController.rust()

    assert conn.status == 200
    assert conn.resp_body =~ "Rust crates inside ojak"
    assert conn.resp_body =~ ~s(<details id="rust-security">)
    refute conn.resp_body =~ "<details open"
    assert conn.resp_body =~ "ed25519-dalek"
    assert conn.resp_body =~ "AS-IS “Thank you!”"
    assert conn.resp_body =~ "Thank you for maintaining this project as open source"
    refute conn.resp_body =~ "<script"

    ja = get("/licenses/rust?lang=ja") |> LegalController.rust() |> Map.get(:resp_body)
    assert ja =~ "ojak の中の Rust クレート"
    assert ja =~ ~s(href="/licenses?lang=ja")
    assert ja =~ "そのままの、感謝を"
  end

  test "/credits has a Korean page, and the three pages link each other" do
    ko = get("/credits?lang=ko") |> LegalController.credits() |> Map.get(:resp_body)

    assert ko =~ ~s(<html lang="ko">)
    assert ko =~ "크레딧"
    assert ko =~ "작고, 취소할 수 없는"
    assert ko =~ "이 감사는 양도할 수 없습니다."
    assert ko =~ "연합우주를 널리 알려 주셔서"
    assert ko =~ ~s(href="/credits")
    assert ko =~ ~s(href="/credits?lang=ja")

    en = get("/credits") |> LegalController.credits() |> Map.get(:resp_body)
    assert en =~ ~s(href="/credits?lang=ko")
    assert en =~ ~s(href="/credits?lang=ja")
    # the thanks are translated on en/ja, the Korean original lives on ko
    assert en =~ "spreading the word about the fediverse"
    refute en =~ "연합우주"

    ja = get("/credits?lang=ja") |> LegalController.credits() |> Map.get(:resp_body)
    assert ja =~ ~s(href="/credits?lang=ko")
    assert ja =~ "連合宇宙を広めてくださり"
    refute ja =~ "연합우주"
  end

  test "/credits holds standards and credit — not dependencies — in both languages" do
    en = get("/credits") |> LegalController.credits() |> Map.get(:resp_body)

    assert en =~ "<h1>\nCredits</h1>"
    assert en =~ ~s(<h2 id="standards">)
    assert en =~ ~s(<h2 id="credit">)
    assert en =~ "NodeInfo"
    assert en =~ "RFC 9421"
    assert en =~ "RFC 8785"
    assert en =~ ~s(href="https://fediverse.codeberg.page/fep/fep/8b32/")
    assert en =~ "Mastodon"
    assert en =~ "AS-IS “Thank you!”"
    assert en =~ "This thanks is non-transferable."
    refute en =~ "<script"

    ja = get("/credits?lang=ja") |> LegalController.credits() |> Map.get(:resp_body)
    assert ja =~ "クレジット"
    assert ja =~ ~s(href="/licenses?lang=ja")
    assert ja =~ "そのままの、感謝を"
    assert ja =~ "この感謝は、譲渡できません。"
  end

  test "the people on /credits link to their own sites in every language" do
    for path <- ["/credits", "/credits?lang=ja", "/credits?lang=ko"] do
      body = get(path) |> LegalController.credits() |> Map.get(:resp_body)

      for url <- [
            "https://lapy.link/",
            "https://hongminhee.org/",
            "https://kodingwarrior.github.io/about/"
          ] do
        assert body =~ ~s(href="#{url}"), "#{path} #{url}"
      end
    end

    ko = get("/credits?lang=ko") |> LegalController.credits() |> Map.get(:resp_body)
    assert ko =~ "님은"
    # ltlapy is a person; k.lapy.link is the server, and it is theirs
    assert ko =~ ~s(>ltlapy</a>의 <a href="https://k.lapy.link">)
    refute ko =~ "Jaeyeol"
  end

  test "the open-source thanks closes /licenses but not /credits" do
    lic = get("/licenses") |> LegalController.licenses() |> Map.get(:resp_body)
    assert lic =~ "maintaining this project as open source"
    assert lic =~ "This thanks is non-transferable."

    for {path, lang} <- [
          {"/credits", "en"},
          {"/credits?lang=ja", "ja"},
          {"/credits?lang=ko", "ko"}
        ] do
      body = get(path) |> LegalController.credits() |> Map.get(:resp_body)
      refute body =~ "maintaining this project as open source", lang
      refute body =~ "オープンソースとして", lang
      refute body =~ "오픈소스로서", lang
    end
  end

  test "the standards left /licenses; it points to /credits instead" do
    body = get("/licenses") |> LegalController.licenses() |> Map.get(:resp_body)

    assert body =~ ~s(href="/credits")
    refute body =~ "ActivityPub ·"
    refute body =~ "ECMAScript"
  end

  test "the main page points to the Rust page by a footnote, and no longer lists the crates" do
    body = get("/licenses") |> LegalController.licenses() |> Map.get(:resp_body)

    assert body =~ ~s(href="#note-rust")
    assert body =~ ~s(<p id="note-rust">)
    assert body =~ ".notes p:target"
    assert body =~ ~s(href="/licenses/rust")
    refute body =~ "ed25519-dalek"
  end

  test "/terms?lang=ko serves the Korean version" do
    conn = get("/terms?lang=ko") |> LegalController.terms()

    assert conn.status == 200
    assert conn.resp_body =~ "환영합니다"
  end
end
