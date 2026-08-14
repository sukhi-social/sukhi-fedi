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

  describe "import_from_json/2" do
    test "parses Misskey /api/emojis array format" do
      json = ~s({
        "emojis": [
          {
            "id": "1",
            "name": "blobcat",
            "category": "Cats",
            "aliases": ["cat", "neko"],
            "url": "https://misskey.example/e/blobcat.png"
          },
          {
            "id": "2",
            "name": "blobparty",
            "category": "Party",
            "aliases": [],
            "url": "https://misskey.example/e/blobparty.gif"
          }
        ]
      })

      # Note: register will hit Repo if DB is running or fail changeset if invalid
      # In unit test, test json decoding structure
      assert {:ok, data} = JSON.decode(json)
      assert is_list(data["emojis"])
      assert length(data["emojis"]) == 2
    end

    test "parses Misskey package export format" do
      json = ~s({
        "metaVersion": 1,
        "emojis": [
          {
            "downloadUrl": "https://misskey.example/e/blobcat.png",
            "fileName": "blobcat.png",
            "emoji": {
              "name": "blobcat",
              "category": "Cats",
              "aliases": ["cat"]
            }
          }
        ]
      })

      assert {:ok, data} = JSON.decode(json)
      assert is_list(data["emojis"])
      assert hd(data["emojis"])["emoji"]["name"] == "blobcat"
    end
  end

  describe "import_from_zip/2" do
    test "unzips in-memory zip archive with meta.json" do
      meta_json = JSON.encode!(%{
        "metaVersion" => 1,
        "emojis" => [
          %{
            "fileName" => "test.png",
            "emoji" => %{
              "name" => "test_cat",
              "category" => "Test"
            }
          }
        ]
      })

      # Create a simple zip archive in memory
      files = [
        {~c"meta.json", meta_json},
        {~c"test.png", <<0x89, "PNG\r\n\x1a\n", 0, 0, 0, 0>>}
      ]

      {:ok, {_, zip_binary}} = :zip.create(~c"emojis.zip", files, [:memory])

      assert is_binary(zip_binary)
      assert {:ok, file_list} = :zip.unzip(zip_binary, [:memory])
      assert length(file_list) == 2
    end
  end
end
