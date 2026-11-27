# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.NoteDraftsTest do
  @moduledoc """
  Tests for `SukhiFedi.NoteDrafts` — the server-side compose draft
  (`:misskey_api` addon). One draft per account, scoped by `account_id`,
  never federated.

      make test-pgrust ARGS="test/integration/note_drafts_test.exs"
  """

  use SukhiFedi.IntegrationCase, async: false

  import Ecto.Query

  @moduletag :integration

  alias SukhiFedi.NoteDrafts
  alias SukhiFedi.Schema.{Account, NoteDraft, OutboxEvent}

  describe "upsert/2, get/1, delete/1" do
    test "saves, replaces in place, and reads back the owner's draft" do
      a = create_account!("alice_draft")

      assert {:ok, d1} =
               NoteDrafts.upsert(a, %{"text" => "hi", "visibility" => "unlisted"})

      assert d1.account_id == a.id
      assert d1.text == "hi"
      assert d1.visibility == "unlisted"

      # A second upsert replaces the same row (one draft per account).
      assert {:ok, d2} = NoteDrafts.upsert(a, %{"text" => "hello again"})
      assert d2.id == d1.id
      assert d2.text == "hello again"

      assert %NoteDraft{text: "hello again"} = NoteDrafts.get(a)
      assert 1 == Repo.aggregate(from(d in NoteDraft, where: d.account_id == ^a.id), :count)
    end

    test "rejects a visibility outside the composer's set" do
      a = create_account!("bad_vis_draft")
      assert {:error, %Ecto.Changeset{}} = NoteDrafts.upsert(a, %{"visibility" => "shouting"})
    end

    test "a draft is scoped to its owner" do
      a = create_account!("owner_draft")
      other = create_account!("other_draft")

      {:ok, _} = NoteDrafts.upsert(a, %{"text" => "mine"})

      assert %NoteDraft{text: "mine"} = NoteDrafts.get(a)
      assert is_nil(NoteDrafts.get(other))
    end

    test "delete drops the row and is idempotent; nothing is federated" do
      a = create_account!("prune_draft")
      {:ok, _} = NoteDrafts.upsert(a, %{"text" => "draft"})

      assert :ok = NoteDrafts.delete(a)
      assert is_nil(NoteDrafts.get(a))
      # Idempotent: deleting an absent draft is still :ok.
      assert :ok = NoteDrafts.delete(a)

      # A draft never rides the outbox — no Delete (or any event) is queued.
      assert [] == SukhiFedi.AccountRepo.all(from(e in OutboxEvent))
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> insert_account!()
  end
end
