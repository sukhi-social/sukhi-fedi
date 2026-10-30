# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.RebuildRemoteNoteIdsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.Maintenance.RebuildRemoteNoteIds
  alias SukhiFedi.Schema.{Account, Boost, Bookmark, Note, Reaction}
  alias SukhiFedi.Snowflake

  @published ~U[2026-02-28 03:04:05Z]

  describe "rebuild/2" do
    test "re-mints the id from created_at and carries every FK ref across" do
      author = create_remote_account!("ids_author", "remote.example")
      reactor = create_account!("ids_reactor")
      old = insert_drifted_note!(author, "https://remote.example/notes/drift-1")

      Repo.insert!(%Reaction{emoji: "🐾", account_id: reactor.id, note_id: old.id})
      Repo.insert!(%Boost{account_id: reactor.id, note_id: old.id})
      Repo.insert!(%Bookmark{account_id: reactor.id, note_id: old.id})

      assert {:ok, {old_id, new_id}} =
               RebuildRemoteNoteIds.rebuild(old, RebuildRemoteNoteIds.note_fk_refs())

      assert old_id == old.id
      assert Repo.get(Note, old.id) == nil

      new = Repo.get!(Note, new_id)
      assert new.ap_id == "https://remote.example/notes/drift-1"
      assert new.content == "drifted"
      assert DateTime.compare(new.created_at, @published) == :eq
      # The id now encodes the authored time, so id order == date order.
      assert DateTime.to_unix(Snowflake.to_datetime(new_id)) == DateTime.to_unix(@published)

      assert Repo.get_by(Reaction, account_id: reactor.id, emoji: "🐾").note_id == new_id
      assert Repo.get_by(Boost, account_id: reactor.id).note_id == new_id
      assert Repo.get_by(Bookmark, account_id: reactor.id).note_id == new_id
      assert Repo.aggregate(Reaction, :count, :id) == 1
    end
  end

  describe "target_notes/0" do
    test "picks the drifted remote note; leaves in-step and local ones; a second run is a no-op" do
      author = create_remote_account!("ids_target", "remote.example")
      drifted = insert_drifted_note!(author, "https://remote.example/notes/drift-2")

      in_step =
        insert_note!(
          author,
          Snowflake.encode(DateTime.to_unix(@published, :millisecond), 7),
          @published
        )
        |> set_ap_id!("https://remote.example/notes/in-step")

      local = Repo.insert!(%Note{account_id: author.id, content: "local", visibility: "public"})

      ids = RebuildRemoteNoteIds.target_notes() |> Enum.map(& &1.id)
      assert drifted.id in ids
      refute in_step.id in ids
      refute local.id in ids

      assert %{reminted: 1, errors: 0} = RebuildRemoteNoteIds.run(:execute)
      refute drifted.id in (RebuildRemoteNoteIds.target_notes() |> Enum.map(& &1.id))
      assert RebuildRemoteNoteIds.target_notes() == []
    end
  end

  # A remote note inserted "now" (id from the insert clock) but published in
  # February, as a back-filled thread is. The id is given explicitly and the
  # ap_id set afterwards, so nothing re-mints it on the way in.
  defp insert_drifted_note!(author, ap_id) do
    now_id =
      Snowflake.encode(System.system_time(:millisecond), System.unique_integer([:positive]))

    insert_note!(author, now_id, @published) |> set_ap_id!(ap_id)
  end

  defp insert_note!(author, id, created_at) do
    Repo.insert!(%Note{
      id: id,
      account_id: author.id,
      content: "drifted",
      visibility: "public",
      domain: "remote.example",
      created_at: created_at
    })
  end

  defp set_ap_id!(%Note{} = note, ap_id) do
    Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [ap_id: ap_id])
    %{note | ap_id: ap_id}
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  defp create_remote_account!(username, domain) do
    %Account{
      username: username,
      display_name: username,
      summary: "",
      domain: domain,
      actor_uri: "https://#{domain}/users/#{username}",
      inbox_url: "https://#{domain}/users/#{username}/inbox"
    }
    |> Repo.insert!()
  end
end
