# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.StaticFilesTest do
  # Not async: the two roots come from process-wide env vars.
  use ExUnit.Case, async: false

  alias SukhiFedi.Web.StaticFiles

  setup do
    root = Path.join(System.tmp_dir!(), "static_files_test_#{System.unique_integer([:positive])}")
    override = Path.join(root, "override")
    baked = Path.join(root, "baked")
    File.mkdir_p!(override)
    File.mkdir_p!(baked)

    System.put_env("STATIC_OVERRIDE_DIR", override)
    System.put_env("STATIC_BAKED_DIR", baked)

    on_exit(fn ->
      System.delete_env("STATIC_OVERRIDE_DIR")
      System.delete_env("STATIC_BAKED_DIR")
      File.rm_rf!(root)
    end)

    %{override: override, baked: baked}
  end

  defp write(root, relative, body) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  test "emoji come from the override dir", %{override: o} do
    full = write(o, "emojis/neocat/neocat.png", "png")

    assert StaticFiles.resolve("emojis/neocat/neocat.png") == full
    assert StaticFiles.resolve("emojis/nowhere.png") == nil
  end

  test "everything else comes from the baked tree", %{baked: b} do
    full = write(b, "avatar-default.svg", "<svg/>")

    assert StaticFiles.resolve("avatar-default.svg") == full
    assert StaticFiles.resolve("nowhere.svg") == nil
  end

  # The two do not fall through to each other. A stale copy of a baked file
  # left in the override dir (an old SPA push put some there) must not
  # answer; and an emoji missing from the override dir is a 404, not
  # whatever the release happens to hold under that name.
  test "a tree answers only for its own paths", %{override: o, baked: b} do
    write(o, "avatar-default.svg", "stale push")
    write(b, "emojis/neocat.png", "baked emoji")

    assert StaticFiles.resolve("avatar-default.svg") == nil
    assert StaticFiles.resolve("emojis/neocat.png") == nil
  end

  # 983 emoji files came out of a zip at mode 0700, and the container
  # stopped running as root. `File.regular?` only stats, so every one of
  # them answered 200 and then died on eacces halfway through the body —
  # a 502 to the client, a success in the log.
  test "a file it cannot read is not offered", %{override: o} do
    unreadable = write(o, "emojis/locked.png", "png")
    File.chmod!(unreadable, 0o000)

    # As root, modes mean nothing and there is no case to make.
    if File.read(unreadable) == {:error, :eacces} do
      assert StaticFiles.resolve("emojis/locked.png") == nil
    end
  end

  test "will not walk out of either tree", %{override: o, baked: b} do
    write(o, "emojis/a.png", "png")
    write(b, "avatar-default.svg", "<svg/>")
    File.write!(Path.join(Path.dirname(o), "secret"), "no")

    assert StaticFiles.resolve("emojis/../../secret") == nil
    assert StaticFiles.resolve("../secret") == nil
  end
end
