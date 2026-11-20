# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule ImportPgTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv
  @moduletag :needs_pg

  alias SukhiHosi.{ImportPg, Actors, Notes, Pg, Store}

  @domain "sukhi.test"

  # the columns of sukhi's `accounts` and `notes` that the import reads
  setup do
    Pg.reset!(SpikePg)

    for t <- ["accounts", "notes"], do: Postgrex.query!(SpikePg, "DROP TABLE IF EXISTS #{t}", [])

    Postgrex.query!(SpikePg, "CREATE TABLE accounts (id bigserial PRIMARY KEY, username text NOT NULL, domain text, actor_uri text)", [])

    Postgrex.query!(
      SpikePg,
      """
      CREATE TABLE notes (id bigserial PRIMARY KEY, account_id bigint NOT NULL, ap_id text, content text NOT NULL DEFAULT '',
        content_html text, visibility text NOT NULL DEFAULT 'public', domain text,
        created_at timestamptz NOT NULL DEFAULT now(), in_reply_to_ap_id text)
      """,
      []
    )

    {db, _dir} = TestDb.open()
    %{db: db, pg: SpikePg}
  end

  defp account(pg, name, host \\ nil, uri \\ nil) do
    %{rows: [[id]]} = Postgrex.query!(pg, "INSERT INTO accounts (username, domain, actor_uri) VALUES ($1, $2, $3) RETURNING id", [name, host, uri])
    id
  end

  defp note(pg, account_id, iri, opts \\ []) do
    Postgrex.query!(
      pg,
      "INSERT INTO notes (account_id, ap_id, content, content_html, visibility, domain, created_at, in_reply_to_ap_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
      [
        account_id,
        iri,
        Keyword.get(opts, :content, "text of #{iri}"),
        opts[:html],
        Keyword.get(opts, :visibility, "public"),
        opts[:domain],
        Keyword.get(opts, :at, ~U[2026-11-01 00:00:00.000123Z]),
        opts[:reply_to]
      ]
    )
  end

  defp both_actors(c) do
    alice = account(c.pg, "alice")
    bob = account(c.pg, "bob", "remote.test", "https://remote.test/users/bob")
    assert %{copied: 2} = ImportPg.actors(c.db, c.pg, domain: @domain)
    {alice, bob}
  end

  test "people: ours are built from the domain, a remote one is as stored; again is the same", c do
    account(c.pg, "alice")
    account(c.pg, "bob", "remote.test", "https://remote.test/users/bob")
    ghost = account(c.pg, "ghost", "remote.test", nil)

    assert %{copied: 2, already: 0, skipped: [{^ghost, :no_iri}]} = ImportPg.actors(c.db, c.pg, domain: @domain, batch: 2)
    assert %{copied: 0, already: 2} = ImportPg.actors(c.db, c.pg, domain: @domain)

    alice = Actors.find(c.db, "https://sukhi.test/users/alice")
    bob = Actors.find(c.db, "https://remote.test/users/bob")
    assert [%{"actor/local?": [true], "actor/username": ["alice"]}] = Store.entities(c.db, [alice])
    assert [%{"actor/local?": [false], "actor/host": ["remote.test"]}] = Store.entities(c.db, [bob])
  end

  test "posts: what is shown, when, whose, how far it reaches; and nothing is told", c do
    {alice, bob} = both_actors(c)
    note(c.pg, alice, "https://sukhi.test/notes/1", content: "plain &lt;", html: "<p>rendered</p>", visibility: "followers")
    note(c.pg, bob, "https://remote.test/n/2", content: "<p>theirs</p>", domain: "remote.test", visibility: "mystery")

    assert %{copied: 2, already: 0, missing: []} = ImportPg.notes(c.db, c.pg, domain: @domain)

    mine = Notes.get(c.db, Notes.find(c.db, "https://sukhi.test/notes/1"))
    assert %{html: "<p>rendered</p>", visibility: :followers, published: 1_793_491_200_000_123} = mine
    assert mine.author == Actors.find(c.db, "https://sukhi.test/users/alice")

    theirs = Notes.get(c.db, Notes.find(c.db, "https://remote.test/n/2"))
    assert %{html: "<p>theirs</p>", visibility: :direct} = theirs

    assert [%{"object/local?": [true]}] = Store.entities(c.db, [mine.id])
    assert [%{"object/local?": [false]}] = Store.entities(c.db, [theirs.id])

    assert [] = Store.rows(c.db, "[:find ?o :where [?o :outbox/kind _]]")
    assert [] = Store.rows(c.db, "[:find ?n :where [?n :notification/type _]]")
  end

  test "a thread: the parent may have the larger id, and the root is the top of what we hold", c do
    {alice, bob} = both_actors(c)
    # ids 1..4: leaf, middle, top (the parent has the larger id), and a reply to a post we do not hold
    note(c.pg, bob, "https://remote.test/n/leaf", reply_to: "https://sukhi.test/notes/middle")
    note(c.pg, alice, "https://sukhi.test/notes/middle", reply_to: "https://remote.test/n/top")
    note(c.pg, bob, "https://remote.test/n/top")
    note(c.pg, alice, "https://sukhi.test/notes/orphan", reply_to: "https://elsewhere.test/n/gone")

    assert %{copied: 4, missing: []} = ImportPg.notes(c.db, c.pg, domain: @domain, batch: 1)

    id = &Notes.find(c.db, &1)
    root = &(Notes.get(c.db, id.(&1)).root)

    assert root.("https://remote.test/n/leaf") == id.("https://remote.test/n/top")
    assert root.("https://sukhi.test/notes/middle") == id.("https://remote.test/n/top")
    assert root.("https://remote.test/n/top") == id.("https://remote.test/n/top")
    assert root.("https://sukhi.test/notes/orphan") == id.("https://sukhi.test/notes/orphan")

    assert [%{"object/in-reply-to": [parent]}] = Store.entities(c.db, [id.("https://remote.test/n/leaf")])
    assert parent == id.("https://sukhi.test/notes/middle")
    assert [e] = Store.entities(c.db, [id.("https://sukhi.test/notes/orphan")])
    refute Map.has_key?(e, :"object/in-reply-to")
  end

  test "again is the same; a post with no author or no IRI is named, not dropped", c do
    {alice, _bob} = both_actors(c)
    stranger = account(c.pg, "stranger", "remote.test", "https://remote.test/users/stranger")
    note(c.pg, alice, "https://sukhi.test/notes/1")
    note(c.pg, stranger, "https://remote.test/n/s")
    note(c.pg, alice, nil)
    %{rows: [[no_iri]]} = Postgrex.query!(c.pg, "SELECT id FROM notes WHERE ap_id IS NULL", [])
    %{rows: [[from_stranger]]} = Postgrex.query!(c.pg, "SELECT id FROM notes WHERE ap_id = 'https://remote.test/n/s'", [])

    # the stranger was never copied
    assert %{copied: 1, already: 0, missing: missing} = ImportPg.notes(c.db, c.pg, domain: @domain)
    assert Enum.sort(missing) == Enum.sort([{no_iri, :no_ap_id}, {from_stranger, :no_author}])

    assert %{copied: 0, already: 1} = ImportPg.notes(c.db, c.pg, domain: @domain)

    # the missing one is made good by copying the people and running again
    assert %{copied: 1} = ImportPg.actors(c.db, c.pg, domain: @domain)
    assert %{copied: 1, already: 1, missing: [{^no_iri, :no_ap_id}]} = ImportPg.notes(c.db, c.pg, domain: @domain)
  end

  test "verify says what is there and what is not", c do
    {alice, _bob} = both_actors(c)
    note(c.pg, alice, "https://sukhi.test/notes/1")
    note(c.pg, alice, "https://sukhi.test/notes/2")

    assert %{accounts: 2, notes: 2, actors: 2, notes_found: 0, absent: [{:note, 1}, {:note, 2}]} =
             ImportPg.verify(c.db, c.pg, domain: @domain)

    ImportPg.notes(c.db, c.pg, domain: @domain)
    assert %{notes_found: 2, absent: []} = ImportPg.verify(c.db, c.pg, domain: @domain)
  end
end
