defmodule UnboostTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv
  @moduletag :needs_pg

  alias SukhiHosi.{Actors, Feeder, Follows, Notes, Notifications, Pg, Timeline}

  setup do
    {db, _dir} = TestDb.open()
    Pg.reset!(SpikePg)
    alice = Actors.create_local(db, "alice")
    bob = Actors.create_local(db, "bob")
    carol = Actors.create_local(db, "carol")
    {:ok, n} = Notes.post(db, alice, "https://x/n/1", "hello")
    %{db: db, pg: SpikePg, alice: alice, bob: bob, carol: carol, n: n}
  end

  test "taking a boost back takes the boost and its notification away, and tells the relay", c do
    :ok = Follows.follow(c.db, c.carol, c.bob, state: :accepted)
    :ok = Notes.boost(c.db, c.n, c.bob)
    assert [%{type: :reblog}] = Notifications.list(c.db, c.alice)
    assert c.n in Enum.map(Timeline.home(c.db, c.carol), & &1.id)

    assert :ok = Notes.unboost(c.db, c.n, c.bob)

    assert [] = Notifications.list(c.db, c.alice)
    refute c.n in Enum.map(Timeline.home(c.db, c.carol), & &1.id)

    Feeder.run_once(c.pg, c.db, "a")
    subjects = c.pg |> Pg.outbox_rows() |> Enum.map(& &1.subject)
    assert "sns.outbox.announce.created" in subjects
    assert "sns.outbox.announce.undone" in subjects
  end

  test "taking back what is not there changes nothing and tells no one", c do
    assert :not_boosted = Notes.unboost(c.db, c.n, c.bob)

    :ok = Notes.boost(c.db, c.n, c.bob)
    :ok = Notes.unboost(c.db, c.n, c.bob)
    assert :not_boosted = Notes.unboost(c.db, c.n, c.bob)

    Feeder.run_once(c.pg, c.db, "a")
    assert 1 = c.pg |> Pg.outbox_rows() |> Enum.count(&(&1.subject == "sns.outbox.announce.undone"))
  end

  test "only the one who boosted can take it back; the other boost and its notification stay", c do
    :ok = Notes.boost(c.db, c.n, c.bob)
    :ok = Notes.boost(c.db, c.n, c.carol)
    assert :not_boosted = Notes.unboost(c.db, c.n, c.alice)

    assert :ok = Notes.unboost(c.db, c.n, c.bob)
    assert [%{type: :reblog, from: from}] = Notifications.list(c.db, c.alice)
    assert from == c.carol
  end

  test "boosting again after taking back makes a new boost, and tells again", c do
    :ok = Notes.boost(c.db, c.n, c.bob)
    :ok = Notes.unboost(c.db, c.n, c.bob)
    assert :ok = Notes.boost(c.db, c.n, c.bob)
    assert [%{type: :reblog}] = Notifications.list(c.db, c.alice)
    assert :already = Notes.boost(c.db, c.n, c.bob)
  end

  # a write and a read at once: the JVM khana only (dtlv is one process per call and falls over)
  @tag :concurrent_read
  test "taken back at the same moment from two places: once, one line for the relay", c do
    :ok = Notes.boost(c.db, c.n, c.bob)

    results = 1..6 |> Task.async_stream(fn _ -> Notes.unboost(c.db, c.n, c.bob) end, max_concurrency: 6, timeout: 30_000) |> Enum.map(&elem(&1, 1))
    assert Enum.sort(results) == [:not_boosted, :not_boosted, :not_boosted, :not_boosted, :not_boosted, :ok]

    Feeder.run_once(c.pg, c.db, "a")
    assert 1 = c.pg |> Pg.outbox_rows() |> Enum.count(&(&1.subject == "sns.outbox.announce.undone"))
  end
end
