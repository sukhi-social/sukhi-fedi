# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PreviewCardsTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.PreviewCards

  describe "first_link/2" do
    test "picks the first external http(s) link, skipping our own domain" do
      content = ~s(see https://sukhi.test/users/me/notes/1 and https://example.com/post then bye)
      assert PreviewCards.first_link(content, "sukhi.test") == "https://example.com/post"
    end

    test "is nil when there's no external link" do
      assert PreviewCards.first_link("just words, no links", "sukhi.test") == nil
      assert PreviewCards.first_link("https://sukhi.test/x", "sukhi.test") == nil
    end

    test "trims a trailing period off a sentence-final URL" do
      assert PreviewCards.first_link("read https://example.com/a.", "sukhi.test") ==
               "https://example.com/a"
    end
  end

  describe "parse_og/2" do
    test "pulls OpenGraph title/description/image and site name" do
      html = """
      <html><head>
      <meta property="og:title" content="Hello &amp; World">
      <meta content="A nice page" property="og:description">
      <meta property="og:image" content="https://cdn.example/i.png">
      <meta property="og:site_name" content="Example">
      </head><body>...</body></html>
      """

      card = PreviewCards.parse_og(html, "https://example.com/p")
      assert card["title"] == "Hello & World"
      assert card["description"] == "A nice page"
      assert card["image"] == "https://cdn.example/i.png"
      assert card["provider_name"] == "Example"
    end

    test "falls back to <title> and the host when OG tags are absent" do
      html = "<html><head><title>Plain Title</title></head><body>x</body></html>"
      card = PreviewCards.parse_og(html, "https://example.com/p")
      assert card["title"] == "Plain Title"
      assert card["provider_name"] == "example.com"
      assert card["type"] == "link"
    end
  end

  describe "fetch_card/1 SSRF fence" do
    test "refuses loopback, private, link-local and cloud-metadata hosts" do
      for url <- [
            "http://127.0.0.1/",
            "http://localhost/",
            "http://10.0.0.5/",
            "http://192.168.1.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://172.16.0.1/"
          ] do
        assert PreviewCards.fetch_card(url) == :error, "expected #{url} to be refused"
      end
    end

    test "refuses non-http(s) schemes and odd ports" do
      assert PreviewCards.fetch_card("ftp://example.com/x") == :error
      assert PreviewCards.fetch_card("http://example.com:22/x") == :error
      assert PreviewCards.fetch_card("not a url") == :error
    end
  end
end
