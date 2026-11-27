# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.MirrorBoomerangTest do
  @moduledoc """
  Our own Create comes back to our inbox whenever a local user has
  local followers (delivery POSTs to their inboxes) or a relay
  forwards our post. The mirror must refuse to mint a second row for
  a note whose id lives on our own host — the real row already exists
  with `ap_id` NULL, so the ap_id unique index cannot catch this.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.AP.Instructions.Mirror
  alias SukhiFedi.{Notes, Polls}
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Note, Poll}

  test "our own Create delivered back to our inbox does not mint a second row" do
    alice = create_account!("boomerang_alice")

    {:ok, note} =
      Notes.create_status(alice, %{"status" => "boomerang", "visibility" => "public"})

    domain = SukhiFedi.Config.domain!()
    actor = "https://#{domain}/users/#{alice.username}"
    canonical = "#{actor}/notes/#{note.id}"

    activity = %{
      "type" => "Create",
      "actor" => actor,
      "object" => %{
        "type" => "Note",
        "id" => canonical,
        "attributedTo" => actor,
        "content" => "<p>boomerang</p>",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }
    }

    count_before = Repo.aggregate(Note, :count, :id)

    assert :ok = Mirror.maybe_mirror_create_note(activity)

    assert Repo.aggregate(Note, :count, :id) == count_before
    # The local note now carries the canonical ap_id itself, so exactly one
    # row holds it — the original. The boomerang must not mint a second.
    assert [%Note{id: id}] = Repo.all(from(n in Note, where: n.ap_id == ^canonical))
    assert id == note.id
  end

  describe "maybe_handle_update/1 — Update(Question)" do
    test "refreshes a mirrored poll's tallies from a newer snapshot" do
      {note, _author} = remote_poll_note!("https://remote.example/notes/q1")

      :ok =
        Polls.ingest_remote_poll(note.id, %{
          "oneOf" => [
            %{"name" => "A", "replies" => %{"totalItems" => 0}},
            %{"name" => "B", "replies" => %{"totalItems" => 0}}
          ],
          "votersCount" => 0
        })

      update = %{
        "type" => "Update",
        "actor" => "https://remote.example/users/voter",
        "object" => %{
          "type" => "Question",
          "id" => "https://remote.example/notes/q1",
          "oneOf" => [
            %{"name" => "A", "replies" => %{"totalItems" => 5}},
            %{"name" => "B", "replies" => %{"totalItems" => 2}}
          ],
          "votersCount" => 7
        }
      }

      assert :ok = Mirror.maybe_handle_update(update)

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)
      {:ok, ctx} = Polls.get_with_results(pid, nil)
      assert ctx.tallies[Enum.at(ctx.options, 0).id] == 5
      assert ctx.tallies[Enum.at(ctx.options, 1).id] == 2
      assert ctx.voters_count == 7
    end

    test "self-heals a note that was mirrored without its poll" do
      {note, _author} = remote_poll_note!("https://remote.example/notes/q2")
      refute Polls.has_poll?(note.id)

      update = %{
        "type" => "Update",
        "actor" => "https://remote.example/users/voter",
        "object" => %{
          "type" => "Question",
          "id" => "https://remote.example/notes/q2",
          "oneOf" => [
            %{"name" => "x", "replies" => %{"totalItems" => 3}},
            %{"name" => "y", "replies" => %{"totalItems" => 1}}
          ],
          "votersCount" => 4
        }
      }

      assert :ok = Mirror.maybe_handle_update(update)
      assert Polls.has_poll?(note.id)
    end

    test "refuses an Update whose object lives on a different host than the actor" do
      {note, _author} = remote_poll_note!("https://remote.example/notes/q3")

      :ok =
        Polls.ingest_remote_poll(note.id, %{
          "oneOf" => [%{"name" => "A", "replies" => %{"totalItems" => 0}}, %{"name" => "B"}],
          "votersCount" => 0
        })

      # actor on evil.example tries to refresh remote.example's poll
      update = %{
        "type" => "Update",
        "actor" => "https://evil.example/users/attacker",
        "object" => %{
          "type" => "Question",
          "id" => "https://remote.example/notes/q3",
          "oneOf" => [
            %{"name" => "A", "replies" => %{"totalItems" => 999}},
            %{"name" => "B", "replies" => %{"totalItems" => 999}}
          ],
          "votersCount" => 999
        }
      }

      assert :ok = Mirror.maybe_handle_update(update)

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)
      {:ok, ctx} = Polls.get_with_results(pid, nil)
      # untouched — the cross-host update was refused
      assert ctx.voters_count == 0
    end
  end

  describe "maybe_handle_update/1 — Update(Note/Article) edit" do
    test "an empty body does not wipe the stored post" do
      {note, _author} = remote_poll_note!("https://remote.example/notes/edit1")

      update = %{
        "type" => "Update",
        "actor" => "https://remote.example/users/rq",
        "object" => %{
          "type" => "Note",
          "id" => "https://remote.example/notes/edit1",
          "content" => ""
        }
      }

      assert :ok = Mirror.maybe_handle_update(update)
      assert %Note{content: "q"} = Repo.get(Note, note.id)
    end

    test "a non-empty edit still replaces the body" do
      {note, _author} = remote_poll_note!("https://remote.example/notes/edit2")

      update = %{
        "type" => "Update",
        "actor" => "https://remote.example/users/rq",
        "object" => %{
          "type" => "Note",
          "id" => "https://remote.example/notes/edit2",
          "content" => "<p>edited</p>"
        }
      }

      assert :ok = Mirror.maybe_handle_update(update)
      assert %Note{content: content} = Repo.get(Note, note.id)
      assert content =~ "edited"
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> insert_account!()
  end

  defp remote_poll_note!(ap_id) do
    author =
      insert_account!(%Account{
        username: "rq_#{System.unique_integer([:positive])}",
        display_name: "rq",
        summary: "",
        domain: "remote.example",
        actor_uri: "https://remote.example/users/rq"
      })

    note =
      Repo.insert!(%Note{
        account_id: author.id,
        content: "q",
        visibility: "public",
        ap_id: ap_id,
        domain: URI.parse(ap_id).host
      })

    {note, author}
  end
end
