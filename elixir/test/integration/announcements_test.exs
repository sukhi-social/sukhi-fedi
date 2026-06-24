# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.AnnouncementsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Announcements
  alias SukhiFedi.Schema.Account

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  defp hour_from_now(h) do
    DateTime.utc_now() |> DateTime.add(h * 3600, :second) |> DateTime.truncate(:second)
  end

  describe "active_for/1" do
    test "shows published, in-window announcements newest first; read=false until dismissed" do
      reader = create_account!("ann_reader")

      {:ok, _old} = Announcements.create(%{content: "first", published: true})
      {:ok, _new} = Announcements.create(%{content: "second", published: true})

      pairs = Announcements.active_for(reader.id)
      assert [{a1, false}, {a2, false}] = pairs
      # newest first (descending published_at, then id)
      assert a1.content == "second"
      assert a2.content == "first"
    end

    test "hides drafts and out-of-window announcements" do
      reader = create_account!("ann_window")

      {:ok, _draft} = Announcements.create(%{content: "draft", published: false})

      {:ok, _future} =
        Announcements.create(%{content: "future", published: true, starts_at: hour_from_now(1)})

      {:ok, _past} =
        Announcements.create(%{content: "past", published: true, ends_at: hour_from_now(-1)})

      {:ok, _live} =
        Announcements.create(%{
          content: "live",
          published: true,
          starts_at: hour_from_now(-1),
          ends_at: hour_from_now(1)
        })

      assert [{%{content: "live"}, false}] = Announcements.active_for(reader.id)
    end
  end

  describe "dismiss/2" do
    test "marks read for that reader only, and is idempotent" do
      alice = create_account!("ann_alice")
      bob = create_account!("ann_bob")
      {:ok, ann} = Announcements.create(%{content: "hello", published: true})

      assert :ok = Announcements.dismiss(alice.id, ann.id)
      # dismissing twice is fine
      assert :ok = Announcements.dismiss(alice.id, ann.id)

      assert [{_, true}] = Announcements.active_for(alice.id)
      # bob hasn't dismissed — still unread for him
      assert [{_, false}] = Announcements.active_for(bob.id)
    end

    test "can't dismiss a draft (not active) — no leaking existence" do
      reader = create_account!("ann_draft")
      {:ok, draft} = Announcements.create(%{content: "secret", published: false})

      assert {:error, :not_found} = Announcements.dismiss(reader.id, draft.id)
    end
  end

  describe "admin CRUD" do
    test "create publishes and stamps published_at; update edits; delete removes" do
      {:ok, ann} = Announcements.create(%{content: "v1", published: true})
      assert ann.published
      assert ann.published_at != nil

      {:ok, edited} = Announcements.update(ann.id, %{content: "v2"})
      assert edited.content == "v2"
      # published_at is kept across an edit
      assert edited.published_at == ann.published_at

      assert {:ok, _} = Announcements.delete(ann.id)
      assert {:error, :not_found} = Announcements.get(ann.id)
    end

    test "an unpublished draft carries no published_at" do
      {:ok, draft} = Announcements.create(%{content: "draft", published: false})
      refute draft.published
      assert draft.published_at == nil
    end
  end
end
