# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule TailTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv
  @moduletag :needs_pg

  alias SukhiHosi.{Actors, Notes, Pg, Store, Tail}

  @domain "sukhi.test"

  setup do
    Pg.reset!(SpikePg)
    for t <- ["reactions", "notes", "accounts"], do: Postgrex.query!(SpikePg, "DROP TABLE IF EXISTS #{t}", [])
    Postgrex.query!(SpikePg, "CREATE TABLE accounts (id bigserial PRIMARY KEY, username text NOT NULL, domain text, actor_uri text)", [])

    Postgrex.query!(
      SpikePg,
      "CREATE TABLE notes (id bigserial PRIMARY KEY, account_id bigint NOT NULL, ap_id text, content text NOT NULL DEFAULT '', content_html text, visibility text NOT NULL DEFAULT 'public', domain text, created_at timestamptz NOT NULL DEFAULT now(), in_reply_to_ap_id text)",
      []
    )

    Postgrex.query!(
      SpikePg,
      "CREATE TABLE reactions (id bigserial PRIMARY KEY, account_id bigint NOT NULL, note_id bigint NOT NULL, emoji text NOT NULL)",
      []
    )

    {db, _dir} = TestDb.open()
    %{db: db, pg: SpikePg, source: {SukhiHosi.Source.Postgres, SpikePg}}
  end

  defp account(pg, name, host \\ nil, uri \\ nil) do
    %{rows: [[id]]} = Postgrex.query!(pg, "INSERT INTO accounts (username, domain, actor_uri) VALUES ($1, $2, $3) RETURNING id", [name, host, uri])
    id
  end

  defp note(pg, account_id, iri, opts \\ []) do
    %{rows: [[id]]} =
      Postgrex.query!(
        pg,
        "INSERT INTO notes (account_id, ap_id, content, created_at, in_reply_to_ap_id) VALUES ($1, $2, $3, $4, $5) RETURNING id",
        [account_id, iri, "text", Keyword.get(opts, :at, DateTime.utc_now()), opts[:reply_to]]
      )

    id
  end

  defp like(pg, account_id, note_id, emoji \\ "⭐") do
    %{rows: [[id]]} =
      Postgrex.query!(pg, "INSERT INTO reactions (account_id, note_id, emoji) VALUES ($1, $2, $3) RETURNING id", [account_id, note_id, emoji])

    id
  end

  defp liked_by(db, note_iri) do
    [e] = Store.entities(db, [Notes.find(db, note_iri)])
    for a <- Map.get(e, :"object/liked-by", []), do: a
  end

  defp sync(c, opts \\ []), do: Tail.sync(c.db, c.source, [domain: @domain] ++ opts)

  defp cursor(db, name) do
    c = Store.lookup(db, :"relay/name", name)
    [e] = Store.entities(db, [c])
    hd(e[:"relay/cursor"])
  end

  test "each round writes what is new, and the cursor is where it got to", c do
    alice = account(c.pg, "alice")
    n1 = note(c.pg, alice, "https://sukhi.test/notes/1")

    assert %{actors: 1, notes: 1, missing: [], skipped: []} = sync(c)
    assert Notes.find(c.db, "https://sukhi.test/notes/1")
    assert cursor(c.db, "tail:accounts") == alice and cursor(c.db, "tail:notes") == n1

    assert %{actors: 0, notes: 0} = sync(c)

    bob = account(c.pg, "bob", "remote.test", "https://remote.test/users/bob")
    n2 = note(c.pg, bob, "https://remote.test/n/2")
    assert %{actors: 1, notes: 1} = sync(c, batch: 1)
    assert cursor(c.db, "tail:accounts") == bob and cursor(c.db, "tail:notes") == n2
    assert Actors.find(c.db, "https://remote.test/users/bob")
  end

  test "a reply comes in with its parent, though the parent has the larger id", c do
    alice = account(c.pg, "alice")
    note(c.pg, alice, "https://sukhi.test/notes/reply", reply_to: "https://sukhi.test/notes/parent")
    note(c.pg, alice, "https://sukhi.test/notes/parent")

    assert %{notes: 2} = sync(c)
    parent = Notes.find(c.db, "https://sukhi.test/notes/parent")
    assert Notes.get(c.db, Notes.find(c.db, "https://sukhi.test/notes/reply")).root == parent
  end

  test "a post not stamped yet holds the round at it; the ones before it are written", c do
    alice = account(c.pg, "alice")
    n1 = note(c.pg, alice, "https://sukhi.test/notes/1")
    young = note(c.pg, alice, nil)
    note(c.pg, alice, "https://sukhi.test/notes/3")

    assert %{notes: 1, missing: []} = sync(c)
    assert cursor(c.db, "tail:notes") == n1
    assert Notes.find(c.db, "https://sukhi.test/notes/3") == nil

    # the stamp arrives
    Postgrex.query!(c.pg, "UPDATE notes SET ap_id = 'https://sukhi.test/notes/2' WHERE id = $1", [young])
    assert %{notes: 2} = sync(c)
    assert Notes.find(c.db, "https://sukhi.test/notes/2") && Notes.find(c.db, "https://sukhi.test/notes/3")
  end

  test "a post that never got an IRI is given up on after the grace, and named", c do
    alice = account(c.pg, "alice")
    old = note(c.pg, alice, nil, at: DateTime.add(DateTime.utc_now(), -3600))
    n2 = note(c.pg, alice, "https://sukhi.test/notes/2")

    assert %{notes: 1, missing: [{^old, :no_ap_id}]} = sync(c)
    assert cursor(c.db, "tail:notes") == n2
  end

  test "a post whose author the source does not have is named, not waited for", c do
    alice = account(c.pg, "alice")
    note(c.pg, 9_999, "https://sukhi.test/notes/orphan")
    n2 = note(c.pg, alice, "https://sukhi.test/notes/2")
    orphan = n2 - 1

    assert %{notes: 1, missing: [{^orphan, :no_author}]} = sync(c)
    assert cursor(c.db, "tail:notes") == n2
  end

  test "a person with no IRI is named; what was written before is not written again", c do
    ghost = account(c.pg, "ghost", "remote.test", nil)
    account(c.pg, "alice")

    assert %{actors: 1, skipped: [{^ghost, :no_iri}]} = sync(c)
    assert %{actors: 0, skipped: []} = sync(c)
  end

  test "a favourite is followed after its post; another emoji is not, and a second round has nothing to do", c do
    alice = account(c.pg, "alice")
    bob = account(c.pg, "bob", "remote.test", "https://remote.test/users/bob")
    n1 = note(c.pg, alice, "https://sukhi.test/notes/1")
    l1 = like(c.pg, bob, n1)
    like(c.pg, alice, n1, "🎉")

    assert %{likes: 1, likes_missing: []} = sync(c)
    assert liked_by(c.db, "https://sukhi.test/notes/1") == [Actors.find(c.db, "https://remote.test/users/bob")]
    assert cursor(c.db, "tail:likes") == l1

    assert %{likes: 0, likes_missing: []} = sync(c)

    l2 = like(c.pg, alice, n1)
    assert %{likes: 1} = sync(c, batch: 1)
    assert cursor(c.db, "tail:likes") == l2
    assert length(liked_by(c.db, "https://sukhi.test/notes/1")) == 2
  end

  test "a like waits for its post, and the likes before it are written", c do
    alice = account(c.pg, "alice")
    bob = account(c.pg, "bob")
    n1 = note(c.pg, alice, "https://sukhi.test/notes/1")
    young = note(c.pg, alice, nil)
    l1 = like(c.pg, bob, n1)
    like(c.pg, bob, young)

    assert %{likes: 1, likes_missing: []} = sync(c)
    assert cursor(c.db, "tail:likes") == l1

    # the stamp arrives: the post is written by the notes step, then the like, in one round
    Postgrex.query!(c.pg, "UPDATE notes SET ap_id = 'https://sukhi.test/notes/2' WHERE id = $1", [young])
    assert %{notes: 1, likes: 1} = sync(c)
    assert liked_by(c.db, "https://sukhi.test/notes/2") == [Actors.find(c.db, "https://sukhi.test/users/bob")]
  end

  test "a like whose post will never be here is named, and the cursor goes past it", c do
    alice = account(c.pg, "alice")
    bob = account(c.pg, "bob")
    old = note(c.pg, alice, nil, at: DateTime.add(DateTime.utc_now(), -3600))
    gone = like(c.pg, bob, old)
    ghost = like(c.pg, bob, 9_999)
    n3 = note(c.pg, alice, "https://sukhi.test/notes/3")
    l3 = like(c.pg, bob, n3)

    assert %{likes: 1, likes_missing: missing} = sync(c)
    assert Enum.sort(missing) == [{gone, :no_ap_id}, {ghost, :no_note}]
    assert cursor(c.db, "tail:likes") == l3
  end

  test "a like by a person with no IRI is named", c do
    alice = account(c.pg, "alice")
    ghost = account(c.pg, "ghost", "remote.test", nil)
    n1 = note(c.pg, alice, "https://sukhi.test/notes/1")
    l1 = like(c.pg, ghost, n1)

    assert %{likes: 0, likes_missing: [{^l1, :no_iri}]} = sync(c)
    assert liked_by(c.db, "https://sukhi.test/notes/1") == []
  end
end
