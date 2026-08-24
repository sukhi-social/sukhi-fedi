# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.StaticFilesTest do
  # Not async: the choice is driven by process-wide env vars.
  use ExUnit.Case, async: false

  alias SukhiFedi.Web.StaticFiles

  # The bug this file exists for: for ten days the pushed tree could never
  # win, because the comparison was on mtime and a release tarball is
  # unpacked — every baked file stamped `now`. Nothing said so out loud.

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
      System.delete_env("STATIC_OVERRIDE")
      System.delete_env("STATIC_OVERRIDE_ONLY")
      System.delete_env("STATIC_OVERRIDE_ALWAYS")
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

  defp manifest(root, built_at) do
    write(root, ".static-build.json", Jason.encode!(%{"built_at" => built_at}))
  end

  describe "auto — the newer build wins" do
    test "the pushed tree wins when it was built later", %{override: o, baked: b} do
      write(o, "index.html", "pushed")
      write(b, "index.html", "baked")
      manifest(o, 2_000)
      manifest(b, 1_000)

      assert {:override, path} = StaticFiles.resolve("index.html")
      assert File.read!(path) == "pushed"
    end

    test "the release wins when it was built later", %{override: o, baked: b} do
      write(o, "index.html", "pushed")
      write(b, "index.html", "baked")
      manifest(o, 1_000)
      manifest(b, 2_000)

      assert {:baked, path} = StaticFiles.resolve("index.html")
      assert File.read!(path) == "baked"
    end

    test "an unpacked release does not win on freshness alone", %{override: o, baked: b} do
      # What actually happened in production: every baked file's mtime is
      # the moment the tarball was unpacked, which is always newer.
      write(o, "index.html", "pushed")
      manifest(o, 2_000)
      baked_index = write(b, "index.html", "baked")
      manifest(b, 1_000)
      touch_now(baked_index)

      assert {:override, _} = StaticFiles.resolve("index.html")
    end

    test "a tree that says when it was built beats one that doesn't", %{override: o, baked: b} do
      write(o, "index.html", "pushed")
      write(b, "index.html", "baked")
      manifest(b, 1_000)

      assert {:baked, _} = StaticFiles.resolve("index.html")
    end

    test "with neither saying, the pushed one wins", %{override: o, baked: b} do
      write(o, "index.html", "pushed")
      write(b, "index.html", "baked")

      assert {:override, _} = StaticFiles.resolve("index.html")
    end

    test "falls through to the tree that has the file", %{override: o, baked: b} do
      manifest(o, 1_000)
      manifest(b, 2_000)
      write(o, "emojis/neocat.png", "emoji")

      assert {:override, _} = StaticFiles.resolve("emojis/neocat.png")
      assert StaticFiles.resolve("nowhere.png") == nil
    end
  end

  describe "the paths no build produces" do
    test "styles and emojis come from the override even when older", %{override: o, baked: b} do
      write(o, "styles/tokens.css", "pushed")
      write(b, "styles/tokens.css", "baked")
      manifest(o, 1_000)
      manifest(b, 2_000)

      assert {:override, path} = StaticFiles.resolve("styles/tokens.css")
      assert File.read!(path) == "pushed"
    end

    test "STATIC_OVERRIDE_ALWAYS replaces the list", %{override: o, baked: b} do
      System.put_env("STATIC_OVERRIDE_ALWAYS", "brand/")
      write(o, "styles/tokens.css", "pushed")
      write(b, "styles/tokens.css", "baked")
      manifest(o, 1_000)
      manifest(b, 2_000)

      assert {:baked, _} = StaticFiles.resolve("styles/tokens.css")
    end
  end

  describe "when the operator wants the last word" do
    test "prefer takes the override however old it is", %{override: o, baked: b} do
      System.put_env("STATIC_OVERRIDE", "prefer")
      write(o, "index.html", "pushed")
      write(b, "index.html", "baked")
      manifest(o, 1_000)
      manifest(b, 2_000)

      assert {:override, path} = StaticFiles.resolve("index.html")
      assert File.read!(path) == "pushed"
    end

    test "prefer still falls back for files it does not have", %{baked: b} do
      System.put_env("STATIC_OVERRIDE", "prefer")
      write(b, "index.html", "baked")

      assert {:baked, _} = StaticFiles.resolve("index.html")
    end

    test "only never looks at the release", %{override: o, baked: b} do
      System.put_env("STATIC_OVERRIDE", "only")
      write(b, "index.html", "baked")

      assert StaticFiles.resolve("index.html") == nil

      write(o, "index.html", "pushed")
      assert {:override, _} = StaticFiles.resolve("index.html")
    end

    test "STATIC_OVERRIDE_ONLY=true still means only", %{baked: b} do
      System.put_env("STATIC_OVERRIDE_ONLY", "true")
      write(b, "index.html", "baked")

      assert StaticFiles.resolve("index.html") == nil
    end
  end

  # 983 emoji files came out of a zip at mode 0700, and the container
  # stopped running as root. `File.regular?` only stats, so every one of
  # them answered 200 and then died on eacces halfway through the body —
  # a 502 to the client, a success in the log.
  test "a file it cannot read is not offered", %{override: o, baked: b} do
    unreadable = write(o, "index.html", "pushed")
    File.chmod!(unreadable, 0o000)
    write(b, "index.html", "baked")

    # As root, modes mean nothing and there is no case to make.
    if File.read(unreadable) == {:error, :eacces} do
      assert {:baked, _} = StaticFiles.resolve("index.html")
    end
  end

  test "will not walk out of either tree", %{override: o} do
    write(o, "index.html", "pushed")
    File.write!(Path.join(Path.dirname(o), "secret"), "no")

    assert StaticFiles.resolve("../secret") == nil
  end

  defp touch_now(path) do
    now = System.os_time(:second)
    File.touch!(path, now + 60)
  end
end
