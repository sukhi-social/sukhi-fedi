# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule AccountClosingTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv
  @moduletag :needs_pg

  alias SukhiHosi.{AccountClosing, Actors, Feeder, Follows, Markers, Notes, Pg, Store}

  setup do
    {db, _dir} = TestDb.open()
    Pg.reset!(SpikePg)
    alice = Actors.create_local(db, "alice")
    bob = Actors.create_local(db, "bob")
    %{db: db, pg: SpikePg, alice: alice, bob: bob}
  end

  defp relay_takes_all(pg), do: Postgrex.query!(pg, "UPDATE outbox SET status = 'published', published_at = now()", [])
  defp subjects(pg), do: pg |> Pg.outbox_rows() |> Enum.map(& &1.subject)
  defp lines_of(db, who), do: db |> Store.rows("[:find ?e :in $ ?a :where [?e :outbox/actor ?a]]", [[:scalar, who]]) |> length()

  defp populate(c) do
    {:ok, a1} = Notes.post(c.db, c.alice, "https://x/n/a1", "a1")
    {:ok, _} = Notes.post(c.db, c.alice, "https://x/n/a2", "a2")
    {:ok, _} = Notes.post(c.db, c.alice, "https://x/n/a3", "a3")
    {:ok, b1} = Notes.post(c.db, c.bob, "https://x/n/b1", "b1")
    :ok = Notes.like(c.db, a1, c.bob)
    :ok = Notes.like(c.db, b1, c.alice)
    :ok = Follows.follow(c.db, c.bob, c.alice, state: :accepted)
    {:ok, _} = Markers.upsert(c.pg, c.alice, "home", "10")
    {:ok, _} = Markers.upsert(c.pg, c.bob, "home", "20")
    %{a1: a1, b1: b1}
  end

  test "posts go in batches, then the account is told, then it waits for the relay, then both stores let go", c do
    populate(c)

    assert :more = AccountClosing.step(c.db, c.pg, c.alice, batch: 2)
    assert :more = AccountClosing.step(c.db, c.pg, c.alice, batch: 2)
    assert :more = AccountClosing.step(c.db, c.pg, c.alice, batch: 2), "the account is told"

    # the lines are in hosigraph, not yet taken by anyone
    assert :waiting = AccountClosing.step(c.db, c.pg, c.alice)
    Feeder.run_once(c.pg, c.db, "a")
    assert :waiting = AccountClosing.step(c.db, c.pg, c.alice), "copied, but not taken by the relay"

    deletes = Enum.count(subjects(c.pg), &(&1 == "sns.outbox.note.deleted"))
    assert deletes == 3
    assert "sns.outbox.actor.deleted" == List.last(subjects(c.pg)), "the account is told last, after each of its posts"

    relay_takes_all(c.pg)
    assert {:done, %{markers: 1, outbox: out}} = AccountClosing.step(c.db, c.pg, c.alice)
    assert out >= 5

    assert :done = AccountClosing.step(c.db, c.pg, c.alice)
    assert nil == Actors.find_local(c.db, "alice")
    assert 0 = lines_of(c.db, c.alice)
    assert [] = Enum.filter(Pg.outbox_rows(c.pg), &(&1.payload["account_id"] == c.alice))
    assert %{} == Markers.get(c.pg, c.alice, ["home"])
  end

  test "the other person keeps theirs: post, marker, and the lines they caused", c do
    %{b1: b1} = populate(c)
    Feeder.run_once(c.pg, c.db, "a")
    drive(c)

    assert %{html: "b1", likes: 0} = Notes.get(c.db, b1)
    assert %{"home" => %{last_read_id: "20"}} = Markers.get(c.pg, c.bob, ["home"])
    assert Enum.any?(Pg.outbox_rows(c.pg), &(&1.payload["account_id"] == c.bob))
  end

  test "nothing is erased while a line is on its way", c do
    populate(c)
    for _ <- 1..4, do: AccountClosing.step(c.db, c.pg, c.alice)
    Feeder.run_once(c.pg, c.db, "a")

    assert :waiting = AccountClosing.step(c.db, c.pg, c.alice)
    assert Actors.find_local(c.db, "alice") == c.alice
    assert "sns.outbox.note.deleted" in subjects(c.pg)
  end

  test "a line that was never copied is waited for too", c do
    populate(c)
    for _ <- 1..4, do: AccountClosing.step(c.db, c.pg, c.alice)
    Feeder.run_once(c.pg, c.db, "a")
    relay_takes_all(c.pg)
    # a post made after the copy: its Delete is in hosigraph only
    {:ok, late} = Notes.post(c.db, c.alice, "https://x/n/late", "late")
    :ok = Notes.delete(c.db, late, c.alice)

    assert :waiting = AccountClosing.step(c.db, c.pg, c.alice)
    Feeder.run_once(c.pg, c.db, "a")
    relay_takes_all(c.pg)
    assert {:done, _} = AccountClosing.step(c.db, c.pg, c.alice)
  end

  test "a step that stopped after telling the account is made good by running it again: told once", c do
    populate(c)
    for _ <- 1..3, do: AccountClosing.step(c.db, c.pg, c.alice)
    # the mark was lost (the process died between the write and the mark)
    Postgrex.query!(c.pg, "UPDATE account_closings SET actor_deleted_at = NULL WHERE account_id = $1", [c.alice])

    assert :more = AccountClosing.step(c.db, c.pg, c.alice)
    Feeder.run_once(c.pg, c.db, "a")
    assert 1 = Enum.count(subjects(c.pg), &(&1 == "sns.outbox.actor.deleted"))
  end

  test "a step that stopped after the erase finishes on the next", c do
    populate(c)
    Feeder.run_once(c.pg, c.db, "a")
    drive(c)
    Postgrex.query!(c.pg, "UPDATE account_closings SET finished_at = NULL WHERE account_id = $1", [c.alice])

    assert {:done, %{markers: 0, outbox: 0}} = AccountClosing.step(c.db, c.pg, c.alice)
    assert :done = AccountClosing.step(c.db, c.pg, c.alice)
    assert 0 = lines_of(c.db, c.alice)
  end

  # steps, with the feeder and the relay doing their part between them, until it is done
  defp drive(c, left \\ 20) do
    case AccountClosing.step(c.db, c.pg, c.alice, batch: 2) do
      {:done, _} -> :ok
      _ when left == 0 -> flunk("did not finish")
      _ ->
        Feeder.run_once(c.pg, c.db, "a")
        relay_takes_all(c.pg)
        drive(c, left - 1)
    end
  end
end
