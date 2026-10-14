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

  describe "import_many/3" do
    import Ecto.Query

    alias SukhiFedi.Schema.{AdminAudit, OutboxEvent}

    defp admin!(u), do: Repo.insert!(%Account{username: u, display_name: u, summary: ""})

    defp item(name, extra \\ %{}),
      do: Map.merge(%{"shortcode" => name, "image_url" => "https://example.com/#{name}.png"}, extra)

    test "writes every valid item, reports each in input order, audits once" do
      admin = admin!("imp_admin")

      items = [
        item("imp_a", %{"category" => "Pack", "aliases" => ["imp_a2"]}),
        %{"shortcode" => "imp_no_url"},
        item("imp_b"),
        "not an object"
      ]

      assert {:ok, %{imported: 2, failed: 2, dry_run: false, results: results}} =
               CustomEmojis.import_many(items, admin.id)

      assert [
               %{index: 0, shortcode: "imp_a", status: :ok},
               %{index: 1, shortcode: "imp_no_url", status: :error, error: :invalid_emoji_attributes},
               %{index: 2, shortcode: "imp_b", status: :ok},
               %{index: 3, shortcode: nil, status: :error, error: :not_an_object}
             ] = results

      assert %CustomEmoji{category: "Pack"} = CustomEmojis.get_local("imp_a")
      assert %CustomEmoji{} = CustomEmojis.get_local("imp_a2")
      assert CustomEmojis.get_local("imp_no_url") == nil

      audit = Repo.one(from(a in AdminAudit, where: a.action == "emoji_imported"))
      assert audit.admin_account_id == admin.id
      assert audit.metadata["count"] == 2

      assert Repo.aggregate(
               from(e in OutboxEvent, where: e.subject == "sns.outbox.admin.emoji_imported"),
               :count,
               :id
             ) == 1
    end

    test "is an upsert: a second import replaces fields and does not duplicate" do
      admin = admin!("imp_admin2")
      assert {:ok, %{imported: 1}} = CustomEmojis.import_many([item("imp_dup", %{"category" => "A"})], admin.id)
      assert {:ok, %{imported: 1}} = CustomEmojis.import_many([item("imp_dup", %{"category" => "B"})], admin.id)

      assert Repo.aggregate(from(e in CustomEmoji, where: e.shortcode == "imp_dup"), :count, :id) == 1
      assert CustomEmojis.get_local("imp_dup").category == "B"
    end

    test "a domain in the input is ignored: the row is local" do
      admin = admin!("imp_admin6")

      assert {:ok, %{imported: 1}} =
               CustomEmojis.import_many([item("imp_dom", %{"domain" => "evil.example"})], admin.id)

      assert %CustomEmoji{domain: nil} = CustomEmojis.get_local("imp_dom")
    end

    test "dry_run checks and reports but writes nothing, not even an audit row" do
      admin = admin!("imp_admin3")

      assert {:ok, %{imported: 0, failed: 1, dry_run: true, results: [%{status: :ok}, %{status: :error}]}} =
               CustomEmojis.import_many([item("imp_dry"), %{}], admin.id, dry_run: true)

      assert CustomEmojis.get_local("imp_dry") == nil
      refute Repo.exists?(from(a in AdminAudit, where: a.admin_account_id == ^admin.id))
    end

    test "all-invalid input writes nothing (no empty audit row)" do
      admin = admin!("imp_admin4")
      assert {:ok, %{imported: 0, failed: 2}} = CustomEmojis.import_many([%{}, 1], admin.id)
      refute Repo.exists?(from(a in AdminAudit, where: a.admin_account_id == ^admin.id))
    end

    test "empty and oversized batches are refused" do
      admin = admin!("imp_admin5")
      assert {:error, :empty} = CustomEmojis.import_many([], admin.id)
      assert {:error, :too_many} = CustomEmojis.import_many(List.duplicate(%{}, 2_001), admin.id)
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

  # Same helper social_test.exs and conversations_test.exs each carry.
  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end
end
