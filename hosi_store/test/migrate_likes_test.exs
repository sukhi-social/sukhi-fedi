defmodule MigrateLikesTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv
  @moduletag :needs_pg

  alias SukhiHosi.{Actors, MigrateLikes, Notes, Pg, Store}

  setup do
    Pg.reset!(SpikePg)
    Postgrex.query!(SpikePg, "CREATE TABLE IF NOT EXISTS old_likes (id bigserial PRIMARY KEY, note_iri text NOT NULL, actor_iri text NOT NULL)", [])
    Postgrex.query!(SpikePg, "TRUNCATE old_likes RESTART IDENTITY", [])

    {db, _dir} = TestDb.open()
    alice = Actors.create_local(db, "alice")
    bob = Actors.create_local(db, "bob")
    {:ok, n1} = Notes.post(db, alice, "https://x/n/1", "one")
    {:ok, n2} = Notes.post(db, bob, "https://x/n/2", "two")
    %{db: db, pg: SpikePg, alice: alice, bob: bob, n1: n1, n2: n2}
  end

  defp old(pg, note_iri, who), do: Postgrex.query!(pg, "INSERT INTO old_likes (note_iri, actor_iri) VALUES ($1, $2)", [note_iri, who])
  defp alice_iri, do: "https://local.test/users/alice"
  defp bob_iri, do: "https://local.test/users/bob"
  defp likers(db, note), do: db |> Notes.get(note) |> Map.fetch!(:likes)

  defp outbox_lines(db) do
    db |> Store.rows(~s([:find ?o :where [?o :outbox/kind "Like"]])) |> length()
  end

  test "every like is copied, and nothing is told: no line for the relay, no notification", c do
    old(c.pg, "https://x/n/1", bob_iri())
    old(c.pg, "https://x/n/2", alice_iri())
    old(c.pg, "https://x/n/2", bob_iri())
    before = outbox_lines(c.db)

    assert %{copied: 3, already: 0, missing: []} = MigrateLikes.copy(c.db, c.pg)

    assert likers(c.db, c.n1) == 1
    assert likers(c.db, c.n2) == 2
    assert outbox_lines(c.db) == before
    assert [] = Store.rows(c.db, "[:find ?n :where [?n :notification/type :like]]")
  end

  test "run again, it is the same: what is there is counted and left alone", c do
    old(c.pg, "https://x/n/1", bob_iri())
    old(c.pg, "https://x/n/2", alice_iri())

    assert %{copied: 2} = MigrateLikes.copy(c.db, c.pg)
    assert %{copied: 0, already: 2, missing: []} = MigrateLikes.copy(c.db, c.pg)
    assert likers(c.db, c.n1) == 1
  end

  test "a copy that stopped half way is finished by the next one", c do
    old(c.pg, "https://x/n/1", bob_iri())
    old(c.pg, "https://x/n/2", alice_iri())
    old(c.pg, "https://x/n/2", bob_iri())

    # the first one was already copied before it stopped
    {:ok, _} = Hosi.write(c.db, [[:create, c.n1, :"object/liked-by", [:ref, c.bob]]])

    assert %{copied: 2, already: 1} = MigrateLikes.copy(c.db, c.pg, batch: 2)
    assert %{found: 3, absent: [], extra: 0} = MigrateLikes.verify(c.db, c.pg)
  end

  test "the same like twice in the old table is one", c do
    old(c.pg, "https://x/n/1", bob_iri())
    old(c.pg, "https://x/n/1", bob_iri())

    assert %{copied: 1, missing: []} = MigrateLikes.copy(c.db, c.pg)
    assert likers(c.db, c.n1) == 1
  end

  test "a like whose post or person is not in hosigraph is reported, not written, not forgotten", c do
    old(c.pg, "https://x/n/1", bob_iri())
    old(c.pg, "https://x/n/gone", bob_iri())
    old(c.pg, "https://x/n/1", "https://remote.test/users/nobody")

    report = MigrateLikes.copy(c.db, c.pg)

    assert %{copied: 1, already: 0} = report
    assert [{"https://x/n/gone", _}, {"https://x/n/1", "https://remote.test/users/nobody"}] = report.missing

    v = MigrateLikes.verify(c.db, c.pg)
    assert v.source == 3 and v.found == 1

    assert %{
             {"https://x/n/gone", bob_iri()} => :no_note,
             {"https://x/n/1", "https://remote.test/users/nobody"} => :no_actor
           } == Map.new(v.absent)
  end

  test "verify sees what was not copied, and likes hosigraph has that the table does not", c do
    old(c.pg, "https://x/n/1", bob_iri())
    assert %{source: 1, found: 0, absent: [{_, :not_copied}], extra: 0} = MigrateLikes.verify(c.db, c.pg)

    MigrateLikes.copy(c.db, c.pg)
    :ok = Notes.like(c.db, c.n2, c.alice)
    assert %{source: 1, found: 1, absent: [], extra: 1} = MigrateLikes.verify(c.db, c.pg)
  end

  test "more than one batch, and an erased person's like is reported, not brought back", c do
    for i <- 1..7, do: old(c.pg, "https://x/n/1", "https://local.test/users/u#{i}")
    for i <- 1..7, do: Actors.create_local(c.db, "u#{i}")
    {:ok, _} = SukhiHosi.Accounts.erase(c.db, Actors.find_local(c.db, "u3"))

    assert %{copied: 6, missing: [{"https://x/n/1", "https://local.test/users/u3"}]} =
             MigrateLikes.copy(c.db, c.pg, batch: 3)

    assert likers(c.db, c.n1) == 6
  end

  test "a table name that is not a name is refused", c do
    assert_raise ArgumentError, fn -> MigrateLikes.copy(c.db, c.pg, table: "old_likes; drop table outbox") end
  end
end
