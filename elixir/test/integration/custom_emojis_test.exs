# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.CustomEmojisTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{CustomEmojis, Notes, Repo}
  alias SukhiFedi.Schema.Account
  alias SukhiFedi.Schema.CustomEmoji

  describe "register/1 and get_local/1" do
    test "registers a local custom emoji and finds it by shortcode, alias, and colon-wrapped format" do
      attrs = %{
        name: "blobcat_test",
        url: "https://example.com/blobcat.png",
        category: "Cats",
        aliases: ["cat_test", "neko_test"]
      }

      assert {:ok, %CustomEmoji{} = emoji} = CustomEmojis.register(attrs)
      assert emoji.shortcode == "blobcat_test"
      assert emoji.category == "Cats"
      assert "cat_test" in emoji.aliases

      # Find by bare name
      assert %CustomEmoji{} = CustomEmojis.get_local("blobcat_test")

      # Find by colon-wrapped name
      assert %CustomEmoji{} = CustomEmojis.get_local(":blobcat_test:")

      # Find by local @. suffix
      assert %CustomEmoji{} = CustomEmojis.get_local(":blobcat_test@.:")

      # Find by alias
      assert %CustomEmoji{} = CustomEmojis.get_local("cat_test")
      assert %CustomEmoji{} = CustomEmojis.get_local(":neko_test:")
    end

    test "updates existing emoji on conflict" do
      attrs1 = %{name: "dup_test", url: "https://example.com/1.png", category: "A"}
      assert {:ok, _} = CustomEmojis.register(attrs1)

      attrs2 = %{name: "dup_test", url: "https://example.com/2.png", category: "B"}
      assert {:ok, updated} = CustomEmojis.register(attrs2)
      assert updated.image_url == "https://example.com/2.png"
      assert updated.category == "B"
    end
  end

  describe "list_local/1 and list_categories/0" do
    test "lists local emojis and filters by category" do
      CustomEmojis.register(%{name: "cat_a", url: "https://example.com/cat_a.png", category: "Animals"})
      CustomEmojis.register(%{name: "food_a", url: "https://example.com/food_a.png", category: "Food"})

      all = CustomEmojis.list_local()
      assert Enum.any?(all, &(&1.shortcode == "cat_a"))
      assert Enum.any?(all, &(&1.shortcode == "food_a"))

      animals = CustomEmojis.list_local(category: "Animals")
      assert Enum.any?(animals, &(&1.shortcode == "cat_a"))
      refute Enum.any?(animals, &(&1.shortcode == "food_a"))

      categories = CustomEmojis.list_categories()
      assert "Animals" in categories
      assert "Food" in categories
    end
  end

  describe "extract_from_text/1 and note creation" do
    test "extracts custom emojis from text and populates note.emojis" do
      CustomEmojis.register(%{name: "blobby", url: "https://example.com/blobby.png"})
      CustomEmojis.register(%{name: "party", url: "https://example.com/party.gif"})

      extracted = CustomEmojis.extract_from_text("Hello :blobby: and :party@.: and :unknown:!")
      assert length(extracted) == 2
      assert Enum.any?(extracted, &(&1["shortcode"] == "blobby" and &1["url"] == "https://example.com/blobby.png"))
      assert Enum.any?(extracted, &(&1["shortcode"] == "party"))

      # Note creation automatically attaches emojis
      account = create_account!("emoji_author")
      {:ok, note} = Notes.create_status(account, %{"status" => "Look at :blobby: 🎉"})
      assert length(note.emojis) == 1
      assert hd(note.emojis)["shortcode"] == "blobby"
      assert hd(note.emojis)["url"] == "https://example.com/blobby.png"
    end
  end

  describe "import_from_json/2 and import_from_zip/2" do
    test "imports Misskey JSON export" do
      json = JSON.encode!(%{
        "emojis" => [
          %{
            "name" => "imported_json_1",
            "url" => "https://example.com/ij1.png",
            "category" => "Imported"
          },
          %{
            "name" => "imported_json_2",
            "url" => "https://example.com/ij2.png",
            "category" => "Imported"
          }
        ]
      })

      assert {:ok, %{imported: 2, total: 2}} = CustomEmojis.import_from_json(json)
      assert %CustomEmoji{} = CustomEmojis.get_local("imported_json_1")
      assert %CustomEmoji{} = CustomEmojis.get_local("imported_json_2")
    end

    test "imports Misskey zip package with bundled images" do
      meta = JSON.encode!(%{
        "metaVersion" => 1,
        "emojis" => [
          %{
            "fileName" => "cat.png",
            "emoji" => %{
              "name" => "zip_cat",
              "category" => "ZipPack"
            }
          }
        ]
      })

      files = [
        {~c"meta.json", meta},
        {~c"cat.png", <<0x89, "PNG\r\n\x1a\n", 0, 0, 0, 0>>}
      ]

      {:ok, {_, zip_binary}} = :zip.create(~c"pack.zip", files, [:memory])
      assert {:ok, %{imported: 1, total: 1}} = CustomEmojis.import_from_zip(zip_binary)

      emoji = CustomEmojis.get_local("zip_cat")
      assert emoji != nil
      assert emoji.category == "ZipPack"
      assert String.starts_with?(emoji.image_url, "data:image/png;base64,")
    end
  end

  # Same helper social_test.exs and conversations_test.exs each carry.
  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end
end
