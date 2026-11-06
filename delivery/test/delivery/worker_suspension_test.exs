# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Delivery.WorkerSuspensionTest do
  # FEP-f799 on the worker's side: whether a delivery is held, for how long, and
  # what is never held. No network, no database: `mix test --no-start`.
  # The cache is one named table, so not async.
  use ExUnit.Case, async: false

  alias SukhiDelivery.Delivery.Worker
  alias SukhiShared.DeliverySuspension.{Cache, Notice, Policy}

  @now ~U[2026-11-06 12:00:00Z]
  @inbox "https://rest.example/users/a/inbox"
  @shared_inbox "https://rest.example/inbox"
  @policy Policy.default()

  defp notice(overrides \\ []) do
    struct!(
      %Notice{
        id: "https://rest.example/suspensions/1",
        controller: "https://rest.example/users/ops",
        target_kind: :origin,
        target: "https://rest.example",
        revision: 1,
        published: DateTime.add(@now, -600, :second),
        end_time: DateTime.add(@now, 3600, :second),
        effective_start: DateTime.add(@now, -300, :second),
        accepted_at: DateTime.add(@now, -300, :second)
      },
      overrides
    )
  end

  defp note, do: %{"type" => "Create", "object" => %{"type" => "Note", "content" => "hi"}}

  defp hold(inbox, now \\ @now, raw \\ note()),
    do: Worker.suspension_hold(%{"inbox_url" => inbox, "raw_json" => raw}, inbox, now, @policy)

  setup do
    start_supervised!(Cache)
    :ok
  end

  test "with nothing in effect, the delivery goes" do
    assert :go = hold(@inbox)
  end

  test "an inbox under a resting origin is held until the end, plus a spread" do
    Cache.put(notice())

    waits = for _ <- 1..200, do: elem(hold(@inbox), 1)

    assert Enum.all?(waits, &(&1 >= 3600 and &1 <= 3600 + @policy.resume_jitter))
    # the spread is real: a crowd held together does not wake together
    assert length(Enum.uniq(waits)) > 10
  end

  test "it resumes at the end, not before: one second before is held, the end itself goes" do
    Cache.put(notice())
    finish = DateTime.add(@now, 3600, :second)

    assert {:snooze, wait} = hold(@inbox, DateTime.add(finish, -1, :second))
    assert wait in 1..(1 + @policy.resume_jitter)
    assert :go = hold(@inbox, finish)
  end

  test "before it starts, nothing is held" do
    Cache.put(notice(effective_start: DateTime.add(@now, 60, :second)))
    assert :go = hold(@inbox)
  end

  test "an inbox notice holds only that inbox; the shared inbox is not swapped in" do
    Cache.put(notice(target_kind: :inbox, target: @inbox))

    assert {:snooze, _} = hold(@inbox)
    assert :go = hold(@shared_inbox)
  end

  test "another origin, another port, a subdomain: not held" do
    Cache.put(notice())

    assert :go = hold("https://other.example/inbox")
    assert :go = hold("https://rest.example:8443/inbox")
    assert :go = hold("https://www.rest.example/inbox")
  end

  test "the one that cancels it lets everything go, even with a copy still on the queue" do
    Cache.put(notice())
    assert {:snooze, _} = hold(@inbox)

    Cache.put(notice(status: :cancelled, cancelled_at: @now))
    assert :go = hold(@inbox)
  end

  describe "what is never held" do
    setup do
      Cache.put(notice())
      :ok
    end

    @suspension %{
      "id" => "https://other.example/suspensions/9",
      "type" => "DeliverySuspension",
      "attributedTo" => "https://other.example/users/ops"
    }

    test "Create and Update of a DeliverySuspension, and Undo of such a Create" do
      assert :go = hold(@inbox, @now, %{"type" => "Create", "object" => @suspension})
      assert :go = hold(@inbox, @now, %{"type" => "Update", "object" => @suspension})

      undo = %{
        "type" => "Undo",
        "object" => %{"type" => "Create", "id" => "https://x.example/c", "object" => @suspension}
      }

      assert :go = hold(@inbox, @now, undo)
    end

    test "an ordinary Create, Update or Undo is held like anything else" do
      assert {:snooze, _} =
               hold(@inbox, @now, %{"type" => "Create", "object" => %{"type" => "Note"}})

      assert {:snooze, _} =
               hold(@inbox, @now, %{"type" => "Update", "object" => %{"type" => "Note"}})

      assert {:snooze, _} =
               hold(@inbox, @now, %{"type" => "Undo", "object" => "https://x.example/c"})
    end

    test "what looks like it by type alone, or that we cannot read, is held" do
      assert {:snooze, _} =
               hold(@inbox, @now, %{"type" => "Create", "object" => "https://x.example/n"})

      assert {:snooze, _} =
               Worker.suspension_hold(%{"inbox_url" => @inbox}, @inbox, @now, @policy)
    end
  end

  test "a held delivery is announced to telemetry" do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    id = "worker-suspension-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, [:sukhi_delivery, :suspension, :held], &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)

    Cache.put(notice())
    {:snooze, seconds} = hold(@inbox)

    assert_receive {:held, %{count: 1, seconds: ^seconds}, %{host: "rest.example"}}
  end

  @doc false
  def forward(_event, measure, meta, parent), do: send(parent, {:held, measure, meta})
end
