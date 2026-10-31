# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.ScheduledStatusesTest do
  @moduledoc """
  End-to-end tests for `SukhiFedi.ScheduledStatuses`: a status scheduled
  for a future instant persists its params + an Oban job, and the
  `PublishWorker` later replays those params through the real
  `create_status` path (Note insert + transactional outbox).

      make test-pglite ARGS="test/integration/scheduled_statuses_test.exs"

  The test env runs Oban `testing: :inline`, which executes a job
  synchronously the moment it's inserted — that can't model "schedule
  now, publish later", so the scheduling steps run under
  `with_testing_mode(:manual, ...)` (the production engine genuinely
  defers the job) and the worker is then run explicitly, as Oban would
  at `publish_at`.
  """

  use SukhiFedi.IntegrationCase, async: false

  import Ecto.Query

  @moduletag :integration

  alias SukhiFedi.ScheduledStatuses
  alias SukhiFedi.ScheduledStatuses.PublishWorker
  alias SukhiFedi.Schema.{Account, Note, OutboxEvent, ScheduledStatus}

  describe "create/3 then publish" do
    test "schedules a status and the worker publishes it via the real create path" do
      a = create_account!("alice_sched")
      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      scheduled =
        Oban.Testing.with_testing_mode(:manual, fn ->
          assert {:ok, scheduled} =
                   ScheduledStatuses.create(a, %{"status" => "later", "visibility" => "public"}, at)

          # Persisted with the Oban job linked, nothing posted yet.
          assert scheduled.account_id == a.id
          assert scheduled.params["status"] == "later"
          assert is_integer(scheduled.oban_job_id)

          # …and that job is in the store the running Oban reads. Under
          # SUKHI_STORE=datalevin that is not `Repo`; a job written to the
          # wrong store is never picked up and the post never goes out.
          assert %Oban.Job{
                   worker: "SukhiFedi.ScheduledStatuses.PublishWorker",
                   state: "scheduled"
                 } =
                   SukhiFedi.Queue.repo().get(Oban.Job, scheduled.oban_job_id)

          assert [] == published_notes(a.id)

          scheduled
        end)

      # At publish_at Oban would run this; do it explicitly. It goes
      # through `Notes.create_status`, so a Note + its outbox event appear.
      assert :ok = PublishWorker.perform(%Oban.Job{args: %{"scheduled_status_id" => scheduled.id}})

      assert [note] = published_notes(a.id)
      assert note.content == "later"

      ev =
        Repo.one!(
          from(e in OutboxEvent,
            where:
              e.subject == "sns.outbox.note.created" and e.aggregate_id == ^to_string(note.id)
          )
        )

      assert ev.payload["note_id"] == note.id

      # A published schedule is gone from the author's list.
      assert is_nil(Repo.get(ScheduledStatus, scheduled.id))
    end

    test "rejects a time less than 5 minutes ahead" do
      a = create_account!("bob_sched")
      soon = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:error, :too_soon} =
               ScheduledStatuses.create(a, %{"status" => "nope", "visibility" => "public"}, soon)

      assert [] == published_notes(a.id)
    end

    test "rejects an unparseable time" do
      a = create_account!("carol_sched")

      assert {:error, :invalid_time} =
               ScheduledStatuses.create(a, %{"status" => "nope"}, "not-a-date")
    end
  end

  describe "list/1 and cancel/2" do
    test "lists only the owner's schedules and cancel deletes the row + job" do
      a = create_account!("dave_sched")
      other = create_account!("erin_sched")
      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      {a_sched, _} =
        Oban.Testing.with_testing_mode(:manual, fn ->
          {:ok, a_sched} = ScheduledStatuses.create(a, %{"status" => "mine"}, at)
          {:ok, other_sched} = ScheduledStatuses.create(other, %{"status" => "theirs"}, at)
          {a_sched, other_sched}
        end)

      assert [listed] = ScheduledStatuses.list(a)
      assert listed.id == a_sched.id

      # Another author can't fetch or cancel it.
      assert {:error, :not_found} = ScheduledStatuses.get(other, a_sched.id)
      assert {:error, :not_found} = ScheduledStatuses.cancel(other, a_sched.id)

      assert {:ok, _} = ScheduledStatuses.cancel(a, a_sched.id)
      assert [] == ScheduledStatuses.list(a)
    end
  end

  defp published_notes(account_id) do
    Repo.all(from(n in Note, where: n.account_id == ^account_id))
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end
end
