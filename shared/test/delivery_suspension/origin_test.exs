# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.OriginTest do
  use ExUnit.Case, async: true

  alias SukhiShared.DeliverySuspension.Origin

  describe "normalize/1" do
    test "scheme and host are lower-cased, the default port and a trailing slash go" do
      assert {:ok, "https://social.example"} = Origin.normalize("https://SOCIAL.example:443/")
      assert {:ok, "https://social.example"} = Origin.normalize("HTTPS://Social.Example")
      assert {:ok, "https://social.example"} = Origin.normalize("https://social.example/")
    end

    test "another port is another origin" do
      assert {:ok, "https://social.example:8443"} =
               Origin.normalize("https://social.example:8443")

      assert {:ok, "https://social.example:8443"} =
               Origin.normalize("https://social.example:8443/")
    end

    test "a trailing dot on a DNS name is kept: it is a different name" do
      assert {:ok, "https://social.example."} = Origin.normalize("https://social.example.")
      assert {:ok, "https://social.example"} = Origin.normalize("https://social.example")
    end

    test "IDNA 2008, strictly: ß stays ß" do
      assert {:ok, "https://xn--fa-hia.example"} = Origin.normalize("https://faß.example")
      assert {:ok, "https://fass.example"} = Origin.normalize("https://fass.example")
      assert {:ok, "https://xn--fa-hia.example"} = Origin.normalize("https://xn--fa-hia.example")
      assert {:ok, "https://xn--bcher-kva.example"} = Origin.normalize("https://bücher.example")
      assert {:ok, "https://xn--wgv71a119e.example"} = Origin.normalize("https://日本語.example")
    end

    test "a width variant or an invalid A-label is refused, not mapped" do
      assert :error = Origin.normalize("https://ＦＯＯ.example")
      assert :error = Origin.normalize("https://xn--ls8h.example")
      assert :error = Origin.normalize("https://xn--a.example")
    end

    test "a path, query or fragment is not an origin" do
      assert :error = Origin.normalize("https://social.example/users/alice")
      assert :error = Origin.normalize("https://social.example/?x=1")
      assert :error = Origin.normalize("https://social.example?x=1")
      assert :error = Origin.normalize("https://social.example/#frag")
      assert :error = Origin.normalize("https://social.example#frag")
    end

    test "not https, no host, userinfo, backslash" do
      assert :error = Origin.normalize("http://social.example")
      assert :error = Origin.normalize("ftp://social.example")
      assert :error = Origin.normalize("social.example")
      assert :error = Origin.normalize("https://")
      assert :error = Origin.normalize("https:///x")
      assert :error = Origin.normalize("https://user@social.example")
      assert :error = Origin.normalize("https://user:pw@social.example")
      assert :error = Origin.normalize("https://social.example\\@evil.example")
    end

    test "a port must be plain digits in 1..65535" do
      assert :error = Origin.normalize("https://social.example:")
      assert :error = Origin.normalize("https://social.example:0")
      assert :error = Origin.normalize("https://social.example:65536")
      assert :error = Origin.normalize("https://social.example:0443")
      assert :error = Origin.normalize("https://social.example:44a")
      assert :error = Origin.normalize("https://social.example:+443")
      assert :error = Origin.normalize("https://social.example:1:2")
    end

    test "empty labels, spaces, over-long names" do
      assert :error = Origin.normalize("https://a..example")
      assert :error = Origin.normalize("https://.example")
      assert :error = Origin.normalize("https://exa mple.com")
      assert :error = Origin.normalize("https://" <> String.duplicate("a.", 130) <> "example")
    end

    test "IPv4 literals: four plain decimal octets only" do
      assert {:ok, "https://203.0.113.9"} = Origin.normalize("https://203.0.113.9")
      assert {:ok, "https://203.0.113.9:8443"} = Origin.normalize("https://203.0.113.9:8443/")

      for host <- [
            "0x7f.1",
            "127.1",
            "2130706433",
            "0x7f000001",
            "010.0.0.1",
            "1.2.3",
            "1.2.3.4.5",
            "256.0.0.1",
            "1.2.3.04",
            "127.0.0.1."
          ] do
        assert :error = Origin.normalize("https://#{host}"), "#{host} must be refused"
      end
    end

    test "IPv6 literals are written the RFC 5952 way; a zone id is refused" do
      assert {:ok, "https://[2001:db8::1]"} = Origin.normalize("https://[2001:0DB8:0:0:0:0:0:1]")
      assert {:ok, "https://[::1]"} = Origin.normalize("https://[0:0:0:0:0:0:0:1]/")
      assert {:ok, "https://[::]"} = Origin.normalize("https://[::]")
      # the longest run wins; the first of two equal runs wins; a lone 0 is not collapsed
      assert {:ok, "https://[1:0:0:2::3]"} = Origin.normalize("https://[1:0:0:2:0:0:0:3]")
      assert {:ok, "https://[1::2:0:0:3:0]"} = Origin.normalize("https://[1:0:0:2:0:0:3:0]")

      assert {:ok, "https://[2001:db8:0:1:1:1:1:1]"} =
               Origin.normalize("https://[2001:db8:0:1:1:1:1:1]")

      assert {:ok, "https://[2001:db8::1]:8443"} = Origin.normalize("https://[2001:db8::1]:8443")
      assert {:ok, "https://[::ffff:c000:201]"} = Origin.normalize("https://[::ffff:192.0.2.1]")

      assert :error = Origin.normalize("https://[fe80::1%25eth0]")
      assert :error = Origin.normalize("https://[fe80::1%eth0]")
      assert :error = Origin.normalize("https://[::1")
      assert :error = Origin.normalize("https://[not-an-address]")
      assert :error = Origin.normalize("https://[::1]x")
    end

    test "not a string" do
      assert :error = Origin.normalize(nil)
      assert :error = Origin.normalize(42)
      assert :error = Origin.normalize(%{})
    end
  end

  describe "of_delivery_url/1" do
    test "the path and query of an inbox are ignored" do
      assert {:ok, "https://social.example"} =
               Origin.of_delivery_url("https://social.example/users/alice/inbox")

      assert {:ok, "https://social.example"} =
               Origin.of_delivery_url("https://SOCIAL.example:443/inbox?x=1")

      assert {:ok, "https://social.example:8443"} =
               Origin.of_delivery_url("https://social.example:8443/inbox")
    end

    test "a subdomain is not the same origin" do
      assert {:ok, "https://a.social.example"} =
               Origin.of_delivery_url("https://a.social.example/inbox")
    end

    test "what cannot be read is :error, which the caller reads as 'deliver as usual'" do
      assert :error = Origin.of_delivery_url("http://social.example/inbox")
      assert :error = Origin.of_delivery_url("https://user@social.example/inbox")
      assert :error = Origin.of_delivery_url("https://0x7f.1/inbox")
      assert :error = Origin.of_delivery_url("/users/alice/inbox")
      assert :error = Origin.of_delivery_url(nil)
    end
  end
end
