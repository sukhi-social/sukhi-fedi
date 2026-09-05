# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Auth.PasskeysOriginTest do
  use ExUnit.Case, async: false

  alias SukhiFedi.Auth.Passkeys

  setup do
    prev = Application.get_env(:sukhi_fedi, :domain)
    Application.put_env(:sukhi_fedi, :domain, "natadeco.com")
    on_exit(fn -> Application.put_env(:sukhi_fedi, :domain, prev) end)
    :ok
  end

  test "the site and its subdomains over https are allowed" do
    assert Passkeys.origin_allowed?("https://natadeco.com", "https://natadeco.com")
    assert Passkeys.origin_allowed?("https://travel.natadeco.com", "https://natadeco.com")
  end

  test "a look-alike host, http, or another port is not" do
    refute Passkeys.origin_allowed?("https://evilnatadeco.com", "https://natadeco.com")
    refute Passkeys.origin_allowed?("https://natadeco.com.evil.org", "https://natadeco.com")
    refute Passkeys.origin_allowed?("http://travel.natadeco.com", "https://natadeco.com")
    refute Passkeys.origin_allowed?("https://travel.natadeco.com:8443", "https://natadeco.com")
  end

  test "dev's exact http origin still matches itself" do
    Application.put_env(:sukhi_fedi, :domain, "localhost:4000")
    assert Passkeys.origin_allowed?("http://localhost:4000", "http://localhost:4000")
    refute Passkeys.origin_allowed?("http://localhost:5000", "http://localhost:4000")
  end
end
