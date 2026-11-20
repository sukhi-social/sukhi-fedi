# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule EraseTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv
  @moduletag :needs_pg

  alias SukhiHosi.{Accounts, Actors, Erase, Feeder, Markers, Notes, Pg, Store}

  setup do
    Pg.reset!(SpikePg)
    {db, _dir} = TestDb.open()
    alice = Actors.create_local(db, "alice")
    bob = Actors.create_local(db, "bob")
    %{db: db, pg: SpikePg, alice: alice, bob: bob}
  end

  defp lines(pg, who), do: Enum.filter(Pg.outbox_rows(pg), fn r -> r.payload["account_id"] == who end)

  defp setup_both(c) do
    {:ok, a_note} = Notes.post(c.db, c.alice, "https://x/n/a", "alice's secret")
    {:ok, b_note} = Notes.post(c.db, c.bob, "https://x/n/b", "bob's")
    :ok = Notes.like(c.db, b_note, c.alice)
    Feeder.run_once(c.pg, c.db, "a")
    {:ok, _} = Markers.upsert(c.pg, c.alice, "home", "10")
    {:ok, _} = Markers.upsert(c.pg, c.bob, "home", "20")
    %{a_note: a_note, b_note: b_note}
  end

  test "both places let go of the account; the other person keeps theirs", c do
    setup_both(c)
    assert length(lines(c.pg, c.alice)) == 2
    assert length(lines(c.pg, c.bob)) == 1

    assert {:ok, %{markers: 1, outbox: 2}} = Erase.account(c.db, c.pg, c.alice)

    assert [] = lines(c.pg, c.alice)
    assert [_] = lines(c.pg, c.bob)
    assert %{} == Markers.get(c.pg, c.alice, ["home"])
    assert %{"home" => %{last_read_id: "20"}} = Markers.get(c.pg, c.bob, ["home"])
    assert [] = Store.rows(c.db, "[:find ?a :where [?a :actor/username \"alice\"]]", [])
  end

  test "stopped half way (only hosigraph done), calling again finishes Postgres; a third call does nothing", c do
    setup_both(c)
    {:ok, _} = Accounts.erase(c.db, c.alice)
    assert [_, _] = lines(c.pg, c.alice)

    assert {:ok, %{markers: 1, outbox: 2}} = Erase.account(c.db, c.pg, c.alice)
    assert {:ok, %{markers: 0, outbox: 0}} = Erase.account(c.db, c.pg, c.alice)
  end

  test "a line the feeder commits after hosigraph let go is taken by the next call", c do
    setup_both(c)
    {:ok, _} = Erase.account(c.db, c.pg, c.alice)
    # a straggler: a round that read its lines before the erase and committed after
    Postgrex.query!(
      c.pg,
      "INSERT INTO outbox (aggregate_type, aggregate_id, subject, payload, source_id) VALUES ('note','1','sns.outbox.note.created', $1, 999999)",
      [%{note_id: 1, account_id: c.alice}]
    )

    assert {:ok, %{outbox: 1}} = Erase.account(c.db, c.pg, c.alice)
    assert [] = lines(c.pg, c.alice)
  end
end
