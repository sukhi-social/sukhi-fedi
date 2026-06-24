# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.RepliesTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Notes.{Ids, Replies}
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Note}

  describe "public_reply_uris/1" do
    test "lists public replies pointing at the parent, skips non-public ones" do
      alice = create_account!("alice_rep")
      parent = insert_note!(alice.id, "parent", "public", nil)
      parent_uri = Ids.local_note_ap_id(Repo.preload(parent, :account))

      public_reply = insert_note!(alice.id, "me too", "public", parent_uri)
      _private_reply = insert_note!(alice.id, "psst", "direct", parent_uri)
      _unrelated = insert_note!(alice.id, "elsewhere", "public", "https://other/x")

      uris = Replies.public_reply_uris([parent_uri])

      assert uris == [Ids.local_note_ap_id(Repo.preload(public_reply, :account))]
    end

    test "empty when nothing replies to the parent" do
      alice = create_account!("alice_rep_empty")
      parent = insert_note!(alice.id, "lonely", "public", nil)
      parent_uri = Ids.local_note_ap_id(Repo.preload(parent, :account))

      assert Replies.public_reply_uris([parent_uri]) == []
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  defp insert_note!(account_id, content, visibility, in_reply_to_ap_id) do
    %Note{
      account_id: account_id,
      content: content,
      visibility: visibility,
      in_reply_to_ap_id: in_reply_to_ap_id
    }
    |> Repo.insert!()
  end
end
