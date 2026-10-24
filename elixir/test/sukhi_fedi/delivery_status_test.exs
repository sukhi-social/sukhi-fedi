# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.DeliveryStatusTest do
  # Touches the Repo (outbox rows, oban_jobs), so not async.
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{DeliveryStatus, Notes}
  alias SukhiFedi.Schema.Account

  describe "classify/1" do
    test "late beats active beats done; nothing at all is delivered" do
      assert DeliveryStatus.classify([]) == :delivered
      assert DeliveryStatus.classify([:done, :done]) == :delivered
      assert DeliveryStatus.classify([:done, :active]) == :delivering
      assert DeliveryStatus.classify([:active, :late, :done]) == :delayed
    end

    test "job states map to the three signals" do
      for s <- ~w(available scheduled executing), do: assert(DeliveryStatus.job_signal(s) == :active)
      for s <- ~w(retryable discarded), do: assert(DeliveryStatus.job_signal(s) == :late)
      for s <- ~w(completed cancelled), do: assert(DeliveryStatus.job_signal(s) == :done)
    end
  end

  describe "for_own_notes/3" do
    test "follows a post from queued, to sent, to late" do
      a = create_account!("ds_alice")
      {:ok, note} = Notes.create_status(a, %{"status" => "hi", "visibility" => "public"})
      note = Repo.reload!(note)

      # The outbox row is still pending: on its way.
      assert %{note.id => :delivering} == DeliveryStatus.for_own_notes(a.id, [note.id])

      mark_outbox("sns.outbox.note.created", note.id, "published")
      assert %{note.id => :delivered} == DeliveryStatus.for_own_notes(a.id, [note.id])

      # Two inboxes: one done, one still going.
      send_job(note.ap_id <> "/activity", "https://one.example/inbox", "completed")
      send_job(note.ap_id <> "/activity", "https://two.example/inbox", "executing")
      assert %{note.id => :delivering} == DeliveryStatus.for_own_notes(a.id, [note.id])

      # A retry waiting is late, whatever the other inbox did.
      send_job(note.ap_id <> "/activity", "https://three.example/inbox", "retryable")
      assert %{note.id => :delayed} == DeliveryStatus.for_own_notes(a.id, [note.id])
    end

    test "the answer is only the state: no host and no count in it" do
      a = create_account!("ds_nohost")
      {:ok, note} = Notes.create_status(a, %{"status" => "hi", "visibility" => "public"})
      note = Repo.reload!(note)
      mark_outbox("sns.outbox.note.created", note.id, "published")
      send_job(note.ap_id <> "/activity", "https://secret.example/inbox", "retryable")
      send_job(note.ap_id <> "/activity", "https://other.example/inbox", "retryable")

      result = DeliveryStatus.for_own_notes(a.id, [note.id])

      assert result == %{note.id => :delayed}
      refute inspect(result) =~ "example"
    end

    test "someone else's note, and an anonymous viewer, get nothing" do
      a = create_account!("ds_owner")
      b = create_account!("ds_other")
      {:ok, note} = Notes.create_status(a, %{"status" => "hi", "visibility" => "public"})

      assert DeliveryStatus.for_own_notes(b.id, [note.id]) == %{}
      assert DeliveryStatus.for_own_notes(nil, [note.id]) == %{}
      assert DeliveryStatus.for_own_notes(a.id, []) == %{}
    end

    test "a post older than the window says nothing" do
      a = create_account!("ds_old")
      {:ok, note} = Notes.create_status(a, %{"status" => "hi", "visibility" => "public"})
      later = DateTime.add(DateTime.utc_now(), (DeliveryStatus.window_days() + 1) * 86_400, :second)

      assert DeliveryStatus.for_own_notes(a.id, [note.id], later) == %{}
    end
  end

  describe "for_deleted_notes/1" do
    test "reads the Delete's own trip after the note is gone" do
      a = create_account!("ds_del")
      {:ok, note} = Notes.create_status(a, %{"status" => "bye", "visibility" => "public"})
      note = Repo.reload!(note)
      {:ok, _} = Notes.delete_note(a, note.id)

      assert %{note.id => :delivering} == DeliveryStatus.for_deleted_notes([note.id])

      mark_outbox("sns.outbox.note.deleted", note.id, "published")
      send_job(note.ap_id <> "#delete", "https://one.example/inbox", "discarded")

      assert %{note.id => :delayed} == DeliveryStatus.for_deleted_notes([note.id])
    end
  end

  defp create_account!(username) do
    Repo.insert!(%Account{username: username, display_name: username})
  end

  defp mark_outbox(subject, note_id, status) do
    Repo.query!(
      "UPDATE outbox SET status = $1 WHERE subject = $2 AND aggregate_id = $3",
      [status, subject, to_string(note_id)]
    )
  end

  defp send_job(activity_id, inbox, state) do
    Repo.query!(
      """
      INSERT INTO oban_jobs (state, queue, worker, args, max_attempts)
      VALUES ($1, 'delivery', 'SukhiDelivery.Delivery.Worker', $2, 10)
      """,
      [state, %{"activity_id" => activity_id, "inbox_url" => inbox}]
    )
  end
end
