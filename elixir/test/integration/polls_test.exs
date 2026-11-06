# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.PollsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.{Notes, Polls}
  alias SukhiFedi.Schema.{Account, Note, OutboxEvent, Poll, PollOption}

  describe "create_status with poll[…]" do
    test "JSON shape: poll: %{options, expires_in, multiple}" do
      a = create_account!("alice_p_j")

      {:ok, note} =
        Notes.create_status(a, %{
          "status" => "favorite color?",
          "poll" => %{
            "options" => ["red", "blue", "green"],
            "expires_in" => 3600,
            "multiple" => false
          }
        })

      assert [%Poll{id: pid, multiple: false}] =
               Repo.all(from p in Poll, where: p.note_id == ^note.id)

      assert ["red", "blue", "green"] =
               Repo.all(
                 from o in PollOption,
                   where: o.poll_id == ^pid,
                   order_by: [asc: o.position],
                   select: o.title
               )
    end

    test "form shape: poll[options][]" do
      a = create_account!("alice_p_f")

      {:ok, note} =
        Notes.create_status(a, %{
          "status" => "binary",
          "poll[options][]" => ["yes", "no"],
          "poll[expires_in]" => "60",
          "poll[multiple]" => "false"
        })

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)
      assert ["yes", "no"] =
               Repo.all(
                 from o in PollOption,
                   where: o.poll_id == ^pid,
                   order_by: [asc: o.position],
                   select: o.title
               )
    end

    test "fewer than two options rolls the whole transaction back" do
      a = create_account!("alice_p_bad")

      assert {:error, :poll_needs_two_options} =
               Notes.create_status(a, %{
                 "status" => "lonely",
                 "poll" => %{"options" => ["only"]}
               })

      # No note was inserted either — the Multi rollback should be atomic.
      assert Repo.aggregate(from(n in SukhiFedi.Schema.Note, where: n.account_id == ^a.id), :count, :id) == 0
    end
  end

  describe "Polls.get_with_results/2 and vote/3" do
    test "vote tallies + idempotency + own_votes for the viewer" do
      a = create_account!("alice_pv")
      b = create_account!("bob_pv")

      {:ok, note} =
        Notes.create_status(a, %{
          "status" => "?",
          "poll" => %{"options" => ["x", "y"], "expires_in" => 3600}
        })

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)

      assert :ok = Polls.vote(b.id, pid, [0])
      # double-voting collapses to one row via the unique constraint
      assert :ok = Polls.vote(b.id, pid, [0])

      {:ok, ctx} = Polls.get_with_results(pid, b.id)
      assert ctx.tallies[Enum.at(ctx.options, 0).id] == 1
      assert ctx.voted? == true
      assert ctx.voted_option_ids == [Enum.at(ctx.options, 0).id]
      assert ctx.voters_count == 1
    end

    test "single-choice poll rejects multiple choices" do
      a = create_account!("alice_pv2")
      b = create_account!("bob_pv2")

      {:ok, note} =
        Notes.create_status(a, %{
          "status" => "?",
          "poll" => %{"options" => ["x", "y"], "multiple" => false}
        })

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)
      assert {:error, :too_many_choices} = Polls.vote(b.id, pid, [0, 1])
    end

    test "single-choice re-vote replaces the prior ballot, no stuffing (C6)" do
      a = create_account!("alice_pv_rb")
      b = create_account!("bob_pv_rb")

      {:ok, note} =
        Notes.create_status(a, %{
          "status" => "?",
          "poll" => %{"options" => ["x", "y"], "multiple" => false}
        })

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)

      assert :ok = Polls.vote(b.id, pid, [0])
      assert :ok = Polls.vote(b.id, pid, [1])

      {:ok, ctx} = Polls.get_with_results(pid, b.id)
      opt0 = Enum.at(ctx.options, 0).id
      opt1 = Enum.at(ctx.options, 1).id

      assert ctx.tallies[opt0] in [nil, 0]
      assert ctx.tallies[opt1] == 1
      assert ctx.voted_option_ids == [opt1]
      assert ctx.voters_count == 1
    end

    test "expired poll rejects votes" do
      a = create_account!("alice_pv3")
      b = create_account!("bob_pv3")

      {:ok, note} =
        Notes.create_status(a, %{
          "status" => "?",
          "poll" => %{"options" => ["x", "y"]}
        })

      [poll] = Repo.all(from p in Poll, where: p.note_id == ^note.id)

      expired_at = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      poll
      |> Ecto.Changeset.change(%{expires_at: expired_at})
      |> Repo.update!()

      assert {:error, :expired} = Polls.vote(b.id, poll.id, [0])
    end
  end

  describe "ingest_remote_poll/2 (inbound AP Question)" do
    test "snapshots a single-choice poll's options, tallies, voters and expiry" do
      note = remote_note!("https://hackers.pub/notes/abc")

      question = %{
        "type" => "Question",
        "oneOf" => [
          %{"type" => "Note", "name" => "Elixir", "replies" => %{"totalItems" => 3}},
          %{"type" => "Note", "name" => "Rust", "replies" => %{"totalItems" => 5}}
        ],
        "endTime" => "2099-01-01T00:00:00Z",
        "votersCount" => 8
      }

      assert :ok = Polls.ingest_remote_poll(note.id, question)

      [%Poll{id: pid, multiple: false}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)

      {:ok, ctx} = Polls.get_with_results(pid, nil)
      assert Enum.map(ctx.options, & &1.title) == ["Elixir", "Rust"]
      assert ctx.tallies[Enum.at(ctx.options, 0).id] == 3
      assert ctx.tallies[Enum.at(ctx.options, 1).id] == 5
      assert ctx.voters_count == 8
    end

    test "anyOf marks the poll multiple-choice" do
      note = remote_note!("https://hackers.pub/notes/multi")

      question = %{
        "type" => "Question",
        "anyOf" => [
          %{"type" => "Note", "name" => "A", "replies" => %{"totalItems" => 1}},
          %{"type" => "Note", "name" => "B", "replies" => %{"totalItems" => 2}}
        ]
      }

      assert :ok = Polls.ingest_remote_poll(note.id, question)

      [%Poll{id: pid, multiple: true, voters_count: vc}] =
        Repo.all(from p in Poll, where: p.note_id == ^note.id)

      # No votersCount given → fall back to the sum of option tallies.
      assert vc == 3
      {:ok, ctx} = Polls.get_with_results(pid, nil)
      assert ctx.poll.multiple == true
    end

    test "an object without oneOf/anyOf is a no-op" do
      note = remote_note!("https://hackers.pub/notes/plain")
      assert :ok = Polls.ingest_remote_poll(note.id, %{"type" => "Note"})
      assert [] = Repo.all(from p in Poll, where: p.note_id == ^note.id)
    end
  end

  describe "refresh_remote_poll_counts/2" do
    test "updates option tallies and voters from a newer snapshot, by position" do
      note = remote_note!("https://hackers.pub/notes/refresh")

      # First seen at vote-zero, the way the oldest archived Question looks.
      :ok =
        Polls.ingest_remote_poll(note.id, %{
          "oneOf" => [
            %{"type" => "Note", "name" => "A", "replies" => %{"totalItems" => 0}},
            %{"type" => "Note", "name" => "B", "replies" => %{"totalItems" => 0}}
          ],
          "votersCount" => 0
        })

      # The newest archived Update carries the real counts.
      assert :ok =
               Polls.refresh_remote_poll_counts(note.id, %{
                 "oneOf" => [
                   %{"type" => "Note", "name" => "A", "replies" => %{"totalItems" => 7}},
                   %{"type" => "Note", "name" => "B", "replies" => %{"totalItems" => 2}}
                 ],
                 "votersCount" => 9
               })

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)
      {:ok, ctx} = Polls.get_with_results(pid, nil)
      # Titles unchanged, identity preserved; only the counts moved.
      assert Enum.map(ctx.options, & &1.title) == ["A", "B"]
      assert ctx.tallies[Enum.at(ctx.options, 0).id] == 7
      assert ctx.tallies[Enum.at(ctx.options, 1).id] == 2
      assert ctx.voters_count == 9
    end

    test "no_poll when the note owns no poll yet" do
      note = remote_note!("https://hackers.pub/notes/refresh-nopoll")

      assert :no_poll =
               Polls.refresh_remote_poll_counts(note.id, %{
                 "oneOf" => [%{"name" => "A"}, %{"name" => "B"}]
               })
    end
  end

  describe "vote/3 federates a remote-poll ballot and surfaces local votes" do
    test "voting on a remote poll enqueues a Create(Note) ballot at the Question" do
      voter = create_account!("voter_rp")
      note = remote_note!("https://remote.example/users/pollster/notes/poll1")

      :ok =
        Polls.ingest_remote_poll(note.id, %{
          "oneOf" => [
            %{"name" => "Elixir", "replies" => %{"totalItems" => 2}},
            %{"name" => "Rust", "replies" => %{"totalItems" => 5}}
          ],
          "votersCount" => 7
        })

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)

      assert :ok = Polls.vote(voter.id, pid, [0])

      assert [%OutboxEvent{payload: payload}] =
               Repo.all(from e in OutboxEvent, where: e.subject == "sns.outbox.vote.created")

      assert payload["question_ap_id"] == note.ap_id
      assert payload["name"] == "Elixir"
      assert payload["account_id"] == voter.id
      assert payload["note_author_id"] == note.account_id
    end

    test "voting on a LOCAL poll enqueues no ballot (the author is us)" do
      a = create_account!("author_lp")
      voter = create_account!("voter_lp")

      {:ok, note} =
        Notes.create_status(a, %{"status" => "?", "poll" => %{"options" => ["x", "y"]}})

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)
      assert :ok = Polls.vote(voter.id, pid, [0])

      assert [] = Repo.all(from e in OutboxEvent, where: e.subject == "sns.outbox.vote.created")
    end

    test "stopgap: a remote poll's tally surfaces local votes the origin hasn't counted" do
      v1 = create_account!("rp_v1")
      v2 = create_account!("rp_v2")
      note = remote_note!("https://remote.example/users/pollster/notes/poll2")

      # Option "A" shows 0 at the origin; two local users vote it here.
      :ok =
        Polls.ingest_remote_poll(note.id, %{
          "oneOf" => [
            %{"name" => "A", "replies" => %{"totalItems" => 0}},
            %{"name" => "B", "replies" => %{"totalItems" => 9}}
          ],
          "votersCount" => 9
        })

      [%Poll{id: pid}] = Repo.all(from p in Poll, where: p.note_id == ^note.id)
      assert :ok = Polls.vote(v1.id, pid, [0])
      assert :ok = Polls.vote(v2.id, pid, [0])

      {:ok, ctx} = Polls.get_with_results(pid, v1.id)
      opt_a = Enum.at(ctx.options, 0).id
      opt_b = Enum.at(ctx.options, 1).id

      # max(remote 0, local 2) = 2 for A; B keeps the origin's 9 (no local).
      assert ctx.tallies[opt_a] == 2
      assert ctx.tallies[opt_b] == 9
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  # A remote note owns an `ap_id`; that's what flips poll rendering onto the
  # cached AP tallies instead of local `poll_votes`.
  defp remote_note!(ap_id) do
    author = create_account!("remote_q_#{System.unique_integer([:positive])}")

    # domain is what marks a note remote now (raw struct skips the
    # changeset's ap_id-host derivation, so set it).
    %Note{
      account_id: author.id,
      content: "q",
      visibility: "public",
      ap_id: ap_id,
      domain: URI.parse(ap_id).host
    }
    |> Repo.insert!()
  end
end
