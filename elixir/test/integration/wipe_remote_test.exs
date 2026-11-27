# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.WipeRemoteTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Maintenance.WipeRemote
  alias SukhiFedi.Schema.{Account, Note, Reaction}

  describe "run/2" do
    test "dry_run reports the remote-note count and deletes nothing" do
      author = create_remote_account!("wipe_dry", "remote.example")
      remote = create_remote_note!(author, "https://remote.example/notes/dry-1")

      assert %{mode: :dry_run, remote_notes: count, cascades: cascades} =
               WipeRemote.run(:dry_run)

      assert count >= 1
      assert {"reactions", "note_id"} in cascades
      # nothing removed
      assert Repo.get(Note, remote.id) != nil
    end

    test "execute wipes remote notes and their cascades, leaves local untouched" do
      author = create_remote_account!("wipe_author", "remote.example")
      local = create_account!("wipe_local")

      remote = create_remote_note!(author, "https://remote.example/notes/gone-1")
      local_note = create_local_note!(local, "a local post that must survive")

      # A local user's reaction on the remote note — cascades away with it.
      Repo.insert!(%Reaction{emoji: "🐾", account_id: local.id, note_id: remote.id})

      accounts_before = Repo.aggregate(Account, :count, :id)

      assert %{mode: :execute, deleted: deleted} = WipeRemote.run(:execute)
      assert deleted >= 1

      # remote note + its dependent reaction gone
      assert Repo.get(Note, remote.id) == nil
      assert Repo.aggregate(Reaction, :count, :id) == 0

      # local note and every account survive
      assert Repo.get(Note, local_note.id) != nil
      assert Repo.aggregate(Account, :count, :id) == accounts_before
    end

    test "domain: scopes the wipe to one peer" do
      a = create_remote_account!("wipe_peer_a", "a.example")
      b = create_remote_account!("wipe_peer_b", "b.example")

      note_a = create_remote_note!(a, "https://a.example/notes/1")
      note_b = create_remote_note!(b, "https://b.example/notes/1")

      assert %{deleted: deleted} = WipeRemote.run(:execute, domain: "a.example")
      assert deleted == 1

      assert Repo.get(Note, note_a.id) == nil
      assert Repo.get(Note, note_b.id) != nil
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> insert_account!()
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
    |> insert_account!()
  end

  defp create_remote_note!(%Account{id: account_id}, ap_id) do
    Repo.insert!(%Note{
      account_id: account_id,
      content: "remote body",
      visibility: "public",
      ap_id: ap_id,
      domain: URI.parse(ap_id).host
    })
  end

  defp create_local_note!(%Account{id: account_id}, content) do
    Repo.insert!(%Note{
      account_id: account_id,
      content: content,
      visibility: "public"
    })
  end
end
