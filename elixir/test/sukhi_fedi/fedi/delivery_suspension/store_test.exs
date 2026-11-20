# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.StoreTest do
  # What the Store promises on its own, apart from the Receiver that uses it:
  # a write replaces by key, says only what it has to say, and a cutoff never
  # goes back. Real PostgreSQL.
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Fedi.DeliverySuspension.Store
  alias SukhiShared.DeliverySuspension.{Notice, Policy}

  @ctl "https://a.example/users/ops"
  @other "https://b.example/users/ops"
  @now ~U[2026-11-20 12:00:00.000000Z]

  defp notice(attrs \\ []) do
    struct!(
      Notice,
      Keyword.merge(
        [
          id: "https://a.example/suspensions/1",
          controller: @ctl,
          target_kind: :inbox,
          target: "https://a.example/inbox",
          revision: 1,
          published: @now
        ],
        attrs
      )
    )
  end

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  describe "notices" do
    test "a notice reads back as it was written, with the Create that carried it" do
      n = notice(accepted_at: @now, effective_start: @now)
      assert :ok = Store.put_notice(n, create_id: "https://a.example/c/1")

      assert {:ok, ^n, "https://a.example/c/1"} = Store.get_notice(n.id)
      assert {:ok, ^n, _} = Store.get_notice_by_create(@ctl, "https://a.example/c/1")
      assert :none = Store.get_notice("https://a.example/suspensions/nope")
      assert :none = Store.get_notice_by_create(@other, "https://a.example/c/1")
      assert {:ok, [^n]} = Store.all_notices()
    end

    test "a notice that arrived as an Update has no Create yet" do
      assert :ok = Store.put_notice(notice())
      assert {:ok, _, nil} = Store.get_notice("https://a.example/suspensions/1")
    end

    test "a second write replaces the notice; one that names no Create leaves the Create alone" do
      assert :ok = Store.put_notice(notice(), create_id: "https://a.example/c/1")
      cancelled = notice(status: :cancelled, revision: 2, cancelled_at: @now)

      assert :ok = Store.put_notice(cancelled)
      assert {:ok, ^cancelled, "https://a.example/c/1"} = Store.get_notice(cancelled.id)
      assert {:ok, [^cancelled]} = Store.all_notices()
      assert Store.count_notices(@ctl) == 1

      assert :ok = Store.put_notice(cancelled, create_id: "https://a.example/c/2")
      assert {:ok, _, "https://a.example/c/2"} = Store.get_notice(cancelled.id)
    end

    test "notices are counted per controller, cancelled ones too" do
      assert :ok = Store.put_notice(notice())
      assert :ok = Store.put_notice(notice(id: "https://a.example/suspensions/2", status: :cancelled))
      assert :ok = Store.put_notice(notice(id: "https://b.example/suspensions/1", controller: @other))

      assert Store.count_notices(@ctl) == 2
      assert Store.count_notices(@other) == 1
      assert Store.count_notices("https://nobody.example/u") == 0
    end
  end

  describe "pending cancellations" do
    test "held until they expire" do
      refute Store.pending?(@ctl, "https://a.example/c/1", @now)

      assert :ok = Store.put_pending(@ctl, "https://a.example/c/1", @now, Policy.default())
      assert Store.pending?(@ctl, "https://a.example/c/1", @now)
      refute Store.pending?(@other, "https://a.example/c/1", @now)
      refute Store.pending?(@ctl, "https://a.example/c/2", @now)

      later = DateTime.add(@now, Policy.default().notice_max_age + 1, :second)
      refute Store.pending?(@ctl, "https://a.example/c/1", later)
    end

    test "dropped once applied" do
      assert :ok = Store.put_pending(@ctl, "https://a.example/c/1", @now, Policy.default())
      assert :ok = Store.delete_pending(@ctl, "https://a.example/c/1")
      refute Store.pending?(@ctl, "https://a.example/c/1", @now)
    end

    test "capped per actor and in all; holding the same one twice is one" do
      policy = %{Policy.default() | max_pending_per_actor: 2, max_pending_total: 3}

      assert :ok = Store.put_pending(@ctl, "c1", @now, policy)
      assert :ok = Store.put_pending(@ctl, "c1", @now, policy)
      assert :ok = Store.put_pending(@ctl, "c2", @now, policy)
      assert {:error, :full} = Store.put_pending(@ctl, "c3", @now, policy)

      assert :ok = Store.put_pending(@other, "c1", @now, policy)
      assert {:error, :full} = Store.put_pending(@other, "c2", @now, policy)
    end
  end

  describe "control evidence" do
    test "an attempt says only what it has to say" do
      assert :none = Store.get_evidence(:inbox, "https://a.example/inbox", @ctl)

      assert :ok =
               Store.put_evidence(:inbox, "https://a.example/inbox", @ctl, %{
                 verified_at: ago(60),
                 attempted_at: ago(60),
                 failure: :none
               })

      assert {:ok, %{verified_at: v, attempted_at: a, failure: nil}} =
               Store.get_evidence(:inbox, "https://a.example/inbox", @ctl)

      assert v == ago(60)
      assert a == ago(60)

      assert :ok =
               Store.put_evidence(:inbox, "https://a.example/inbox", @ctl, %{
                 attempted_at: @now,
                 failure: :unlinked
               })

      assert {:ok, %{verified_at: ^v, attempted_at: attempted, failure: :unlinked}} =
               Store.get_evidence(:inbox, "https://a.example/inbox", @ctl)

      assert attempted == @now

      assert :none = Store.get_evidence(:origin, "https://a.example/inbox", @ctl)
      assert :none = Store.get_evidence(:inbox, "https://a.example/inbox", @other)
    end
  end

  describe "cutoffs" do
    test "none until one is set, and it only moves forward" do
      assert Store.cutoff(@ctl) == nil

      assert :ok = Store.advance_cutoff(@ctl, ago(100))
      assert Store.cutoff(@ctl) == ago(100)

      assert :ok = Store.advance_cutoff(@ctl, ago(500))
      assert Store.cutoff(@ctl) == ago(100)

      assert :ok = Store.advance_cutoff(@ctl, ago(10))
      assert Store.cutoff(@ctl) == ago(10)
      assert Store.cutoff(@other) == nil
    end
  end

  describe "sweep" do
    test "forgets the old, remembering by the line what it forgot" do
      policy = Policy.default()
      old = notice(id: "https://a.example/suspensions/old", published: ago(policy.notice_max_age + 60))
      young = notice(id: "https://a.example/suspensions/young", published: ago(60))

      assert :ok = Store.put_notice(old)
      assert :ok = Store.put_notice(young)

      assert %{notices: 1, pending: 0} = Store.sweep(@now, policy)

      assert :none = Store.get_notice(old.id)
      assert {:ok, ^young, _} = Store.get_notice(young.id)

      # the first instant still acceptable: the forgotten notice's own `published` is refused too
      assert Store.cutoff(@ctl) == DateTime.add(old.published, 1, :microsecond)
    end

    test "forgets the held Undos that have expired, not the ones that have not" do
      policy = Policy.default()
      expired_at = ago(policy.notice_max_age + 60)

      assert :ok = Store.put_pending(@ctl, "gone", expired_at, policy)
      assert :ok = Store.put_pending(@ctl, "kept", @now, policy)

      assert %{notices: 0, pending: 1} = Store.sweep(@now, policy)

      refute Store.pending?(@ctl, "gone", expired_at)
      assert Store.pending?(@ctl, "kept", @now)
    end

    test "an empty store sweeps to nothing" do
      assert %{notices: 0, pending: 0} = Store.sweep(@now, Policy.default())
    end
  end
end
