# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.ConfigTest do
  use ExUnit.Case, async: false

  alias SukhiFedi.Config

  setup do
    prev = Application.get_env(:sukhi_fedi, :domain)
    on_exit(fn -> Application.put_env(:sukhi_fedi, :domain, prev) end)
    :ok
  end

  test "cookie_domain/0 is the public host with a leading dot, port dropped" do
    Application.put_env(:sukhi_fedi, :domain, "natadeco.com")
    assert Config.cookie_domain() == ".natadeco.com"

    Application.put_env(:sukhi_fedi, :domain, "sukhi.example.org:8443")
    assert Config.cookie_domain() == ".sukhi.example.org"
  end

  test "cookie_domain/0 is nil for a bare host (dev's localhost)" do
    Application.put_env(:sukhi_fedi, :domain, "localhost:4000")
    assert Config.cookie_domain() == nil
  end
end
