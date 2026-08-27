# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.RelayTest do
  use ExUnit.Case, async: true

  alias SukhiDelivery.Outbox.{DispatchWorker, Relay}
  alias SukhiDelivery.Schema.OutboxEvent

  describe "job_for/1 — one outbox row becomes one dispatch job" do
    test "carries the subject, the payload and the row id" do
      event = %OutboxEvent{
        id: 42,
        subject: "sns.outbox.note.created",
        payload: %{"note_id" => 7}
      }

      changeset = Relay.job_for(event)

      assert changeset.changes.args == %{
               "outbox_id" => 42,
               "subject" => "sns.outbox.note.created",
               "payload" => %{"note_id" => 7}
             }
    end

    test "lands on the outbox_dispatch queue with the dead-letter budget" do
      changeset = Relay.job_for(%OutboxEvent{id: 1, subject: "sns.outbox.x", payload: %{}})

      assert changeset.changes.queue == "outbox_dispatch"
      assert changeset.changes.worker == "SukhiDelivery.Outbox.DispatchWorker"
      assert changeset.changes.max_attempts == DispatchWorker.max_attempts()
    end
  end
end
