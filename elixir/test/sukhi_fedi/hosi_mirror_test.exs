# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HosiMirrorTest do
  use ExUnit.Case, async: true

  test "it is off unless asked for: no child, nothing started" do
    refute SukhiFedi.HosiMirror.enabled?()
    assert SukhiFedi.HosiMirror.children() == []
  end

  test "a read handed to shadow/3 comes back as it is, asked for or not, built in or not" do
    answer = %{1 => %{favourites: 2}}
    assert SukhiFedi.HosiMirror.shadow(answer, :favourites, [[1]]) == answer

    # asked for, but the mirror is not on: nothing is asked, and nothing goes wrong
    Application.put_env(:sukhi_fedi, :hosi_shadow, true)
    on_exit(fn -> Application.delete_env(:sukhi_fedi, :hosi_shadow) end)
    assert SukhiFedi.HosiMirror.shadow(answer, :favourites, [[1]]) == answer
  end
end
