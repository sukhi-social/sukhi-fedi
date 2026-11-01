# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.InstanceLogoTest do
  use ExUnit.Case, async: true

  alias SukhiShared.InstanceLogo

  test "unset falls back to the bundled favicon" do
    assert InstanceLogo.url("a.example", nil) == "https://a.example/favicon.png"
    assert InstanceLogo.url("a.example", "  ") == "https://a.example/favicon.png"
    refute InstanceLogo.custom?(nil)
  end

  test "a path is made absolute on our own domain" do
    assert InstanceLogo.url("a.example", "/uploads/1/logo.png") == "https://a.example/uploads/1/logo.png"
    assert InstanceLogo.url("localhost:4000", "/l.png") == "http://localhost:4000/l.png"
    assert InstanceLogo.custom?("/l.png")
  end

  test "an https url passes through" do
    assert InstanceLogo.url("a.example", " https://cdn.example/l.svg ") == "https://cdn.example/l.svg"
  end

  test "unusable values are ignored, not echoed" do
    for bad <- ["//evil.example/x.png", "http://cdn.example/l.png", "javascript:alert(1)", "logo.png"] do
      assert InstanceLogo.url("a.example", bad) == "https://a.example/favicon.png"
    end
  end
end
