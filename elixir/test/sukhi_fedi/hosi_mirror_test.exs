# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HosiMirrorTest do
  use ExUnit.Case, async: true

  test "it is off unless asked for: no child, nothing started" do
    refute SukhiFedi.HosiMirror.enabled?()
    assert SukhiFedi.HosiMirror.children() == []
  end
end
