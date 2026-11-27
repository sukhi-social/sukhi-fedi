# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.RebuildFromArchiveTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.Maintenance.RebuildFromArchive
  alias SukhiFedi.Polls
  alias SukhiFedi.Schema.{Account, Note}

  describe "rebuild_note/2" do
    test "backfills cw and created_at from the archived note object" do
      ap_id = "https://remote.example/notes/arch-1"
      note = insert_remote_note(ap_id, cw: nil, created_at: ~U[2026-05-30 06:00:00Z])

      obj = %{
        "id" => ap_id,
        "summary" => "CW: spoilers",
        "published" => "2021-01-02T03:04:05Z"
      }

      assert :updated = RebuildFromArchive.rebuild_note(obj, :execute)

      reloaded = Repo.get!(Note, note.id)
      assert reloaded.cw == "CW: spoilers"
      assert DateTime.compare(reloaded.created_at, ~U[2021-01-02 03:04:05Z]) == :eq
    end

    test "dry_run reports would_update without writing" do
      ap_id = "https://remote.example/notes/arch-2"
      note = insert_remote_note(ap_id, cw: nil, created_at: ~U[2026-05-30 06:00:00Z])

      obj = %{"id" => ap_id, "summary" => "CW", "published" => "2021-01-02T03:04:05Z"}

      assert :would_update = RebuildFromArchive.rebuild_note(obj, :dry_run)

      # untouched
      reloaded = Repo.get!(Note, note.id)
      assert reloaded.cw == nil
      assert DateTime.compare(reloaded.created_at, ~U[2026-05-30 06:00:00Z]) == :eq
    end

    test "no change when the archive adds nothing new" do
      ap_id = "https://remote.example/notes/arch-3"
      insert_remote_note(ap_id, cw: "CW: kept", created_at: ~U[2021-01-02 03:04:05Z])

      # same cw, same published, and an absent summary must not clear cw
      obj = %{"id" => ap_id, "summary" => "CW: kept", "published" => "2021-01-02T03:04:05Z"}
      assert :unchanged = RebuildFromArchive.rebuild_note(obj, :execute)

      obj_no_summary = %{"id" => ap_id, "published" => "2021-01-02T03:04:05Z"}
      assert :unchanged = RebuildFromArchive.rebuild_note(obj_no_summary, :execute)
    end

    test "never clears an existing cw the archive omits" do
      ap_id = "https://remote.example/notes/arch-4"
      note = insert_remote_note(ap_id, cw: "CW: keep me", created_at: ~U[2021-01-02 03:04:05Z])

      assert :unchanged =
               RebuildFromArchive.rebuild_note(%{"id" => ap_id, "published" => "2021-01-02T03:04:05Z"}, :execute)

      assert Repo.get!(Note, note.id).cw == "CW: keep me"
    end

    test "no_local_note when the ap_id is unknown" do
      assert :no_local_note =
               RebuildFromArchive.rebuild_note(%{"id" => "https://remote.example/notes/ghost"}, :execute)
    end

    test "backfills emojis from the archived note's tag" do
      ap_id = "https://remote.example/notes/arch-emoji"
      note = insert_remote_note(ap_id, created_at: ~U[2021-01-02 03:04:05Z])

      obj = %{
        "id" => ap_id,
        "published" => "2021-01-02T03:04:05Z",
        "tag" => [
          %{
            "type" => "Emoji",
            "name" => ":blobcat:",
            "icon" => %{"url" => "https://remote.example/e/blobcat.png"}
          }
        ]
      }

      assert :updated = RebuildFromArchive.rebuild_note(obj, :execute)
      assert [%{"shortcode" => "blobcat"}] = Repo.get!(Note, note.id).emojis
    end

    test "never clears existing emojis the archive omits" do
      ap_id = "https://remote.example/notes/arch-keep-emoji"
      kept = [%{"shortcode" => "kept", "url" => "https://remote.example/e/kept.png"}]
      note = insert_remote_note(ap_id, created_at: ~U[2021-01-02 03:04:05Z], emojis: kept)

      assert :unchanged =
               RebuildFromArchive.rebuild_note(%{"id" => ap_id, "published" => "2021-01-02T03:04:05Z"}, :execute)

      assert Repo.get!(Note, note.id).emojis == kept
    end
  end

  describe "backfill_poll/2" do
    test "ingests the poll for a pre-v0.4.7 remote note that has none" do
      ap_id = "https://hackers.pub/notes/arch-poll"
      note = insert_remote_note(ap_id, created_at: ~U[2026-06-01 00:00:00Z])

      question = %{
        "id" => ap_id,
        "type" => "Question",
        "oneOf" => [
          %{"type" => "Note", "name" => "yes", "replies" => %{"totalItems" => 4}},
          %{"type" => "Note", "name" => "no", "replies" => %{"totalItems" => 1}}
        ],
        "votersCount" => 5
      }

      assert :would_attach = RebuildFromArchive.backfill_poll(question, :dry_run)
      refute Polls.has_poll?(note.id)

      assert :attached = RebuildFromArchive.backfill_poll(question, :execute)

      [pid] =
        Repo.all(from p in SukhiFedi.Schema.Poll, where: p.note_id == ^note.id, select: p.id)

      {:ok, ctx} = Polls.get_with_results(pid, nil)
      assert Enum.map(ctx.options, & &1.title) == ["yes", "no"]
      assert ctx.tallies[Enum.at(ctx.options, 0).id] == 4
      assert ctx.voters_count == 5
    end

    test "is idempotent — a note that already has a poll is left alone" do
      ap_id = "https://hackers.pub/notes/arch-poll-twice"
      insert_remote_note(ap_id, created_at: ~U[2026-06-01 00:00:00Z])

      question = %{
        "id" => ap_id,
        "oneOf" => [
          %{"type" => "Note", "name" => "a", "replies" => %{"totalItems" => 1}},
          %{"type" => "Note", "name" => "b", "replies" => %{"totalItems" => 2}}
        ]
      }

      assert :attached = RebuildFromArchive.backfill_poll(question, :execute)
      assert :already = RebuildFromArchive.backfill_poll(question, :execute)
    end

    test "a non-poll note object is skipped" do
      ap_id = "https://hackers.pub/notes/arch-plain"
      insert_remote_note(ap_id, created_at: ~U[2026-06-01 00:00:00Z])
      assert :no_poll = RebuildFromArchive.backfill_poll(%{"id" => ap_id}, :execute)
    end
  end

  defp insert_remote_note(ap_id, opts) do
    author =
      insert_account!(%Account{
        username: "arch_#{System.unique_integer([:positive])}",
        display_name: "arch",
        summary: "",
        domain: "remote.example",
        actor_uri: "https://remote.example/users/arch"
      })

    Repo.insert!(%Note{
      account_id: author.id,
      content: "body",
      visibility: "public",
      ap_id: ap_id,
      domain: URI.parse(ap_id).host,
      cw: opts[:cw],
      emojis: opts[:emojis] || [],
      created_at: opts[:created_at]
    })
  end
end
