# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.RebuildRemoteNotesTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Maintenance.RebuildRemoteNotes
  alias SukhiFedi.Schema.{Account, Boost, Bookmark, Note, Reaction}

  describe "rebuild/3" do
    test "mints a snowflake id, stamps published, and carries FK refs across" do
      author = create_remote_account!("rebuild_author", "remote.example")
      reactor = create_account!("rebuild_reactor")
      ap_id = "https://remote.example/notes/legacy-1"

      # A legacy row: small serial id, fetch-time created_at.
      old =
        insert_legacy_note!(%Note{
          id: 770_042,
          account_id: author.id,
          content: "the original body",
          visibility: "public",
          ap_id: ap_id,
          domain: URI.parse(ap_id).host,
          created_at: ~U[2026-05-30 06:00:00Z]
        })

      Repo.insert!(%Reaction{emoji: "🐾", account_id: reactor.id, note_id: old.id})
      Repo.insert!(%Boost{account_id: reactor.id, note_id: old.id})
      Repo.insert!(%Bookmark{account_id: reactor.id, note_id: old.id})

      json = %{"content" => "the original body", "published" => "2020-01-02T03:04:05Z"}

      assert {:ok, {770_042, new_id}} =
               RebuildRemoteNotes.rebuild(old, json, RebuildRemoteNotes.note_fk_refs())

      # New id is a snowflake (well above the serial range), old row is gone.
      assert new_id > 1_000_000_000_000
      assert Repo.get(Note, 770_042) == nil

      new = Repo.get!(Note, new_id)
      assert new.ap_id == ap_id
      assert new.content == "the original body"
      assert new.account_id == author.id
      # created_at now the remote publish time, not the fetch time.
      assert DateTime.compare(new.created_at, ~U[2020-01-02 03:04:05Z]) == :eq

      # Every ref moved to the new id — none cascade-deleted.
      assert Repo.get_by(Reaction, account_id: reactor.id, emoji: "🐾").note_id == new_id
      assert Repo.get_by(Boost, account_id: reactor.id).note_id == new_id
      assert Repo.get_by(Bookmark, account_id: reactor.id).note_id == new_id
      assert Repo.aggregate(Reaction, :count, :id) == 1
    end

    test "falls back to the old created_at when the object has no published" do
      author = create_remote_account!("rebuild_nopub", "remote.example")
      ap_id = "https://remote.example/notes/legacy-2"

      old =
        insert_legacy_note!(%Note{
          id: 770_043,
          account_id: author.id,
          content: "no date",
          visibility: "public",
          ap_id: ap_id,
          domain: URI.parse(ap_id).host,
          created_at: ~U[2026-05-30 06:00:00Z]
        })

      assert {:ok, {770_043, new_id}} =
               RebuildRemoteNotes.rebuild(old, %{"content" => "no date"}, RebuildRemoteNotes.note_fk_refs())

      assert DateTime.compare(Repo.get!(Note, new_id).created_at, ~U[2026-05-30 06:00:00Z]) == :eq
    end
  end

  describe "target_notes/0" do
    test "selects remote serial-id notes, excludes local and snowflake ones" do
      author = create_remote_account!("target_author", "remote.example")

      remote_serial =
        insert_legacy_note!(%Note{
          id: 770_044,
          account_id: author.id,
          content: "remote serial",
          visibility: "public",
          ap_id: "https://remote.example/notes/serial",
          domain: "remote.example"
        })

      # Local note (no ap_id) — even with a serial id, not a target.
      _local_serial =
        Repo.insert!(%Note{
          id: 770_045,
          account_id: author.id,
          content: "local serial",
          visibility: "public"
        })

      # Remote note with a snowflake id (default) — already fine.
      snowflake =
        Repo.insert!(%Note{
          account_id: author.id,
          content: "remote snowflake",
          visibility: "public",
          ap_id: "https://remote.example/notes/snow",
          domain: "remote.example"
        })

      ids = RebuildRemoteNotes.target_notes() |> Enum.map(& &1.id)

      assert 770_044 in ids
      refute 770_045 in ids
      refute snowflake.id in ids
      assert remote_serial.id == 770_044
    end
  end

  # The `notes_remote_id_from_published` trigger overwrites `id` on any
  # INSERT that carries an `ap_id`, so a legacy serial-id remote note can't be
  # inserted in one go. Same route the maintenance tool takes: insert with
  # `ap_id` NULL (id kept), then set `ap_id` by UPDATE (trigger is INSERT-only).
  defp insert_legacy_note!(%Note{ap_id: ap_id} = note) do
    inserted = Repo.insert!(%{note | ap_id: nil})
    Repo.query!("UPDATE notes SET ap_id = $1 WHERE id = $2", [ap_id, inserted.id])
    %{inserted | ap_id: ap_id}
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
