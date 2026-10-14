# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Federation.UrlGuardTest do
  # Not async: it flips an application-wide switch for its duration.
  use ExUnit.Case, async: false

  # The same table as the gateway's `SukhiFedi.Federation.UrlGuardTest` — on
  # purpose: this node keeps its own copy of the guard, and the two must make
  # the same decisions. IP literals only, so no DNS is needed.

  alias SukhiDelivery.Federation.UrlGuard

  # config/test.exs turns the guard off so Bypass (http://localhost) can serve
  # the delivery tests; here it must be the real thing.
  setup do
    prev = Application.get_env(:sukhi_delivery, :disable_url_guard)
    Application.put_env(:sukhi_delivery, :disable_url_guard, false)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:sukhi_delivery, :disable_url_guard),
        else: Application.put_env(:sukhi_delivery, :disable_url_guard, prev)
    end)
  end

  test "rejects loopback / private / link-local / metadata targets" do
    refute UrlGuard.safe?("https://127.0.0.1/inbox")
    refute UrlGuard.safe?("https://169.254.169.254/latest/meta-data/")
    refute UrlGuard.safe?("https://10.0.0.5/inbox")
    refute UrlGuard.safe?("https://192.168.1.10/inbox")
    refute UrlGuard.safe?("https://172.16.0.1/inbox")
    refute UrlGuard.safe?("https://100.64.0.1/inbox")
    refute UrlGuard.safe?("https://0.0.0.0/inbox")
    refute UrlGuard.safe?("https://[::1]/inbox")
  end

  test "rejects non-https and malformed urls" do
    refute UrlGuard.safe?("http://1.1.1.1/inbox")
    refute UrlGuard.safe?("ftp://1.1.1.1/inbox")
    refute UrlGuard.safe?("file:///etc/passwd")
    refute UrlGuard.safe?("not a url")
    refute UrlGuard.safe?(nil)
  end

  test "allows a public https target" do
    assert UrlGuard.safe?("https://1.1.1.1/inbox")
  end

  test "rejects the 192.0 special /24s but not the rest of 192.0.0.0/16" do
    refute UrlGuard.safe?("https://192.0.0.5/inbox")
    refute UrlGuard.safe?("https://192.0.2.5/inbox")
    # 192.0.64.0/18 は Automattic(Gravatar) ── 弾くとリモートの avatar が
    # proxy で 502 になる(2026-09-22)。
    assert UrlGuard.safe?("https://192.0.80.239/inbox")
  end
end
