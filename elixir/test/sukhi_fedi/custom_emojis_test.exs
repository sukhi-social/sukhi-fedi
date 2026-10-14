# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.CustomEmojisTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.CustomEmojis

  describe "namespaced/2" do
    test "leaves unicode and local emojis untouched" do
      assert CustomEmojis.namespaced("🐱", nil) == "🐱"
      assert CustomEmojis.namespaced(":blobcat:", nil) == ":blobcat:"
      assert CustomEmojis.namespaced(":blobcat@.:", nil) == ":blobcat@.:"
      assert CustomEmojis.namespaced(":blobcat:", "") == ":blobcat:"
      assert CustomEmojis.namespaced(":blobcat:", ".") == ":blobcat:"
    end

    test "namespaces remote emojis" do
      assert CustomEmojis.namespaced(":blobcat:", "misskey.io") == ":blobcat@misskey.io:"
      assert CustomEmojis.namespaced(":blobcat@.:", "misskey.io") == ":blobcat@misskey.io:"
    end
  end

  describe "split/1" do
    test "splits bare shortcode" do
      assert CustomEmojis.split(":blobcat:") == {"blobcat", nil}
    end

    test "splits local `@.` suffix" do
      assert CustomEmojis.split(":blobcat@.:") == {"blobcat", nil}
    end

    test "splits remote domain" do
      assert CustomEmojis.split(":blobcat@misskey.io:") == {"blobcat", "misskey.io"}
    end

    test "returns nil for non-shortcode strings" do
      assert CustomEmojis.split("🐱") == nil
      assert CustomEmojis.split("hello") == nil
    end
  end
end
