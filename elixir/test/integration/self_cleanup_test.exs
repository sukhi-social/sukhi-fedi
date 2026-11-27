# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.SelfCleanupTest do
  @moduledoc """
  Self-cleanup: hard-delete targeted notes (row + media gone), write the
  ledger, federate the Delete, and confirm the note is absent from every
  local surface.

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.{Notes, SelfCleanup, Timelines}
  alias SukhiFedi.Schema.{Account, Follow, Note, NoteCleanupLedger, OutboxEvent, PinnedNote}

  describe "run/3 :dry_run" do
    test "counts what would be deleted and protects pins + DMs, touching nothing" do
      a = create_account!("cleanup_dry")

      {:ok, plain} = Notes.create_status(a, %{"status" => "old post", "visibility" => "public"})
      {:ok, pinned} = Notes.create_status(a, %{"status" => "pinned post", "visibility" => "public"})
      {:ok, dm} = make_dm!(a)

      Repo.insert!(%PinnedNote{account_id: a.id, note_id: pinned.id})

      assert %{mode: :dry_run, affected: affected, protected: protected} =
               SelfCleanup.run(a.id, :dry_run)

      # the plain public note is in scope; the pin and the DM are held back
      assert affected == 1
      assert protected.pinned == 1
      assert protected.direct == 1

      # nothing deleted — all rows still present
      assert Repo.get(Note, plain.id) != nil
      assert Repo.get(Note, pinned.id) != nil
      assert Repo.get(Note, dm.id) != nil
      assert Repo.aggregate(NoteCleanupLedger, :count, :id) == 0
    end

    test "older_than_days narrows the scope" do
      a = create_account!("cleanup_span")
      {:ok, recent} = Notes.create_status(a, %{"status" => "recent", "visibility" => "public"})
      {:ok, old} = Notes.create_status(a, %{"status" => "old", "visibility" => "public"})
      backdate!(old, 400)

      assert %{affected: 1} = SelfCleanup.run(a.id, :dry_run, older_than_days: 365)

      # neither touched (dry-run)
      assert Repo.get(Note, recent.id) != nil
      assert Repo.get(Note, old.id) != nil
    end
  end

  describe "run/3 :execute" do
    test "hard-deletes the row, writes a ledger row, enqueues Delete(Note)" do
      a = create_account!("cleanup_exec")
      {:ok, note} = Notes.create_status(a, %{"status" => "tidy me", "visibility" => "public"})
      note_id = note.id

      assert %{mode: :execute, affected: 1} = SelfCleanup.run(a.id, :execute, reason: "test")

      # row is gone
      assert Repo.get(Note, note_id) == nil

      # ledger records birth + deletion + reason
      ledger = Repo.get_by!(NoteCleanupLedger, note_id: note_id)
      assert ledger.account_id == a.id
      assert ledger.reason == "test"
      assert %DateTime{} = ledger.note_created_at
      assert %DateTime{} = ledger.deleted_at

      # the SAME federated Delete a manual delete emits
      ev =
        SukhiFedi.AccountRepo.one!(
          from(e in OutboxEvent,
            where:
              e.subject == "sns.outbox.note.deleted" and e.aggregate_id == ^to_string(note_id)
          )
        )

      assert ev.payload["ap_id"] ==
               "https://#{SukhiFedi.Config.domain!()}/users/#{a.username}/notes/#{note_id}"

      assert ev.payload["account_id"] == a.id
    end

    test "note row is gone after execute (note_media cascades with it)" do
      a = create_account!("cleanup_media")
      {:ok, note} = Notes.create_status(a, %{"status" => "gone row", "visibility" => "public"})
      note_id = note.id

      assert %{mode: :execute, affected: 1} = SelfCleanup.run(a.id, :execute)

      # The note row itself is deleted; note_media rows cascade-delete with it.
      assert Repo.get(Note, note_id) == nil

      assert Repo.one(
               from nm in "note_media", where: nm.note_id == ^note_id, select: nm.note_id
             ) == nil
    end

    test "a deleted note is absent from home and public" do
      author = create_account!("cleanup_home_a")
      viewer = create_account!("cleanup_home_v")

      domain = SukhiFedi.Config.domain!()

      Repo.insert!(%Follow{
        follower_uri: "https://#{domain}/users/#{viewer.username}",
        followee_id: author.id,
        state: "accepted"
      })

      {:ok, stays} = Notes.create_status(author, %{"status" => "stays", "visibility" => "public"})
      {:ok, gone} = Notes.create_status(author, %{"status" => "gone", "visibility" => "public"})
      gone_id = gone.id

      # pin `stays` so it's protected (not deleted) and proves the surfaces
      # still show a live note while the deleted one is gone.
      Repo.insert!(%PinnedNote{account_id: author.id, note_id: stays.id})

      assert %{mode: :execute} =
               SelfCleanup.run(author.id, :execute, older_than_days: 0, reason: "test")

      home_ids = viewer |> Timelines.home(limit: 50) |> Enum.map(& &1.id)
      public_ids = Timelines.public(limit: 50) |> Enum.map(& &1.id)

      # the deleted note is gone from both surfaces; the protected one stays
      refute gone_id in home_ids
      refute gone_id in public_ids
      assert stays.id in home_ids
      assert stays.id in public_ids

      # single read also 404s (row is gone)
      assert {:error, :not_found} = Notes.get_note(gone_id, author.id)
      assert Repo.get(Note, stays.id) != nil
    end

    test "is idempotent: a second run deletes nothing more and adds no ledger row" do
      a = create_account!("cleanup_idem")
      {:ok, _note} = Notes.create_status(a, %{"status" => "once", "visibility" => "public"})

      assert %{affected: 1} = SelfCleanup.run(a.id, :execute, reason: "test")
      ledger_after_first = Repo.aggregate(NoteCleanupLedger, :count, :id)

      assert %{affected: 0} = SelfCleanup.run(a.id, :execute, reason: "test")
      assert Repo.aggregate(NoteCleanupLedger, :count, :id) == ledger_after_first
    end

    test "pins and DMs are never deleted" do
      a = create_account!("cleanup_protect")
      {:ok, pinned} = Notes.create_status(a, %{"status" => "pinned", "visibility" => "public"})
      {:ok, dm} = make_dm!(a)

      Repo.insert!(%PinnedNote{account_id: a.id, note_id: pinned.id})

      assert %{affected: 0} = SelfCleanup.run(a.id, :execute, reason: "test")

      assert Repo.get(Note, pinned.id) != nil
      assert Repo.get(Note, dm.id) != nil
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  # A direct (DM) note: minimal insert with visibility "direct".
  defp make_dm!(%Account{id: account_id}) do
    %Note{}
    |> Note.changeset(%{account_id: account_id, content: "secret", visibility: "direct"})
    |> Repo.insert()
  end

  defp backdate!(%Note{id: id}, days) do
    past = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(n in Note, where: n.id == ^id), set: [created_at: past])
  end
end
