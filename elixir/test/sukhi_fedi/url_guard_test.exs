# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.UrlGuardTest do
  use ExUnit.Case, async: true

  # Picked up by the `--only integration` runner; uses IP literals so it
  # needs no external DNS. Keep this table identical to the delivery node's
  # `SukhiDelivery.Federation.UrlGuardTest` (it has its own copy of the guard).
  @moduletag :integration

  alias SukhiFedi.Federation.UrlGuard

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
