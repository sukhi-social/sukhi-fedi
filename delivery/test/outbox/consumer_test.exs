# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.ConsumerTest do
  use ExUnit.Case, async: true

  alias SukhiDelivery.Outbox.Consumer

  describe "handle_event/2 — routing without DB" do
    test "actor.updated without account_id field → :missing_fields" do
      # Hits the routing surface without touching the DB.
      assert :missing_fields = Consumer.dispatch("sns.outbox.actor.updated", %{})
    end

    test "oauth.app_registered is explicitly ignored (local-only)" do
      assert :ignored =
               Consumer.handle_event(
                 "sns.outbox.oauth.app_registered",
                 ~s({"app_id":1,"name":"smoke"})
               )
    end

    test "unknown subject returns :no_handler" do
      assert :no_handler =
               Consumer.handle_event(
                 "sns.outbox.totally.unknown",
                 ~s({"x":1})
               )
    end

    test "malformed JSON is logged but doesn't crash" do
      assert :bad_json =
               Consumer.handle_event("sns.outbox.note.created", "{not json")
    end

    test "non-binary subject body is rejected" do
      # The subscription delivers binary bodies; nothing else is even
      # reachable here. But be defensive: empty string is invalid JSON.
      assert :bad_json = Consumer.handle_event("sns.outbox.note.created", "")
    end
  end

  describe "dispatch/2 — pure routing surface" do
    test "follow.requested missing fields → :missing_fields without crashing" do
      assert :missing_fields = Consumer.dispatch("sns.outbox.follow.requested", %{})
    end

    test "like.created missing fields → :missing_fields" do
      assert :missing_fields = Consumer.dispatch("sns.outbox.like.created", %{})
    end

    test "announce.undone missing fields → :missing_fields" do
      assert :missing_fields = Consumer.dispatch("sns.outbox.announce.undone", %{})
    end

    test "add.created missing fields → :missing_fields" do
      assert :missing_fields = Consumer.dispatch("sns.outbox.add.created", %{})
    end

    test "note.created missing account → :missing_account" do
      assert :missing_account = Consumer.dispatch("sns.outbox.note.created", %{})
    end

    test "note.created with a malformed account_id is structural (:no_actor), never a crash" do
      # Old code ran String.to_integer/1 in actor_for/1, which raised on a
      # non-numeric id → :crashed → an endless transient retry. A bad id is
      # permanent, so it routes to the structural :no_actor path now (and never
      # reaches the DB). The real win is the inverse: a transient DB error is no
      # longer swallowed to :no_actor — it bubbles to :crashed and is retried.
      assert :no_actor =
               Consumer.dispatch("sns.outbox.note.created", %{"account_id" => "not-an-int"})
    end

    test "note.created with local_only: true → :local_only, never touches DB" do
      # deco の「ローカル」投稿。account_id が実在しなくても、DB を
      # 引く前に短絡することを確かめる(malformed account_id のケースと
      # 同じ理由 ── ここで落ちたら本物のクラッシュと見分けがつかない)。
      assert :local_only =
               Consumer.dispatch("sns.outbox.note.created", %{
                 "account_id" => "not-an-int",
                 "local_only" => true
               })
    end

    test "vote.created missing fields → :missing_fields (no crash, no DB)" do
      assert :missing_fields = Consumer.dispatch("sns.outbox.vote.created", %{})
    end

    test "note.deleted missing fields → :missing_fields" do
      assert :missing_fields = Consumer.dispatch("sns.outbox.note.deleted", %{})
    end

    test "follow.backfill missing fields → :missing_fields" do
      assert :missing_fields = Consumer.dispatch("sns.outbox.follow.backfill", %{})
    end

    test "dm.created missing fields → :missing_fields" do
      assert :missing_fields = Consumer.dispatch("sns.outbox.dm.created", %{})
    end
  end
end
