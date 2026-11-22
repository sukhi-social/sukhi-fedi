# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule MigrateLikesSukhiTest do
  # The likes of sukhi's own tables (`reactions` ⨝ `notes` ⨝ `accounts`), after `ImportPg` has copied
  # the people and the posts: the whole road one switch of the config stands on.
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv
  @moduletag :needs_pg

  alias SukhiHosi.{Actors, ImportPg, MigrateLikes, Notes, Pg}

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
      "CREATE TABLE reactions (id bigserial PRIMARY KEY, account_id bigint NOT NULL, note_id bigint NOT NULL, emoji text NOT NULL, UNIQUE (account_id, note_id, emoji))",
      []
    )

    pg = SpikePg
    alice = account(pg, "alice")
    bob = account(pg, "bob", "remote.test", "https://remote.test/users/bob")
    n1 = note(pg, alice, "https://sukhi.test/notes/1")
    n2 = note(pg, bob, "https://remote.test/n/2")

    {db, _dir} = TestDb.open()
    %{db: db, pg: pg, alice: alice, bob: bob, n1: n1, n2: n2}
  end

  defp account(pg, name, host \\ nil, uri \\ nil) do
    %{rows: [[id]]} = Postgrex.query!(pg, "INSERT INTO accounts (username, domain, actor_uri) VALUES ($1, $2, $3) RETURNING id", [name, host, uri])
    id
  end

  defp note(pg, account_id, iri) do
    %{rows: [[id]]} = Postgrex.query!(pg, "INSERT INTO notes (account_id, ap_id) VALUES ($1, $2) RETURNING id", [account_id, iri])
    id
  end

  defp react(pg, account_id, note_id, emoji \\ "⭐"),
    do: Postgrex.query!(pg, "INSERT INTO reactions (account_id, note_id, emoji) VALUES ($1, $2, $3)", [account_id, note_id, emoji])

  defp copy_people(c) do
    ImportPg.actors(c.db, c.pg, domain: @domain)
    ImportPg.notes(c.db, c.pg, domain: @domain)
  end

  defp likers(db, iri), do: db |> Notes.find(iri) |> then(&Notes.get(db, &1)) |> Map.fetch!(:likes)

  test "the favourites of sukhi's tables come over, the other reactions do not; again is the same", c do
    react(c.pg, c.alice, c.n2)
    react(c.pg, c.bob, c.n1)
    react(c.pg, c.bob, c.n2, "🎉")
    copy_people(c)

    assert %{copied: 2, already: 0, missing: []} = MigrateLikes.copy(c.db, c.pg, domain: @domain)
    assert likers(c.db, "https://remote.test/n/2") == 1
    assert likers(c.db, "https://sukhi.test/notes/1") == 1

    assert %{source: 2, found: 2, absent: [], extra: 0} = MigrateLikes.verify(c.db, c.pg, domain: @domain)
    assert %{copied: 0, already: 2} = MigrateLikes.copy(c.db, c.pg, domain: @domain)
  end

  test "who liked is read from the person's IRI: ours built from the domain, a remote one as stored", c do
    react(c.pg, c.alice, c.n2)
    react(c.pg, c.bob, c.n2)
    copy_people(c)
    MigrateLikes.copy(c.db, c.pg, domain: @domain)

    [e] = SukhiHosi.Store.entities(c.db, [Notes.find(c.db, "https://remote.test/n/2")])
    assert Enum.sort(e[:"object/liked-by"]) == Enum.sort([Actors.find(c.db, "https://sukhi.test/users/alice"), Actors.find(c.db, "https://remote.test/users/bob")])
  end

  test "a like whose person has no IRI, or whose post or person was not copied, is named, not written", c do
    ghost = account(c.pg, "ghost", "remote.test", nil)
    react(c.pg, ghost, c.n1)
    react(c.pg, c.alice, c.n1)
    # copy the people and the posts of only some, by running the import before the late ones exist
    copy_people(c)
    late = account(c.pg, "late", "remote.test", "https://remote.test/users/late")
    react(c.pg, late, c.n1)

    report = MigrateLikes.copy(c.db, c.pg, domain: @domain)

    assert %{copied: 1, already: 0, missing: missing} = report
    assert Enum.sort(missing) == Enum.sort([{"https://sukhi.test/notes/1", nil}, {"https://sukhi.test/notes/1", "https://remote.test/users/late"}])

    v = MigrateLikes.verify(c.db, c.pg, domain: @domain)
    assert v.source == 3 and v.found == 1
    assert Enum.all?(v.absent, fn {_, why} -> why == :no_actor end)
  end

  test "the old table of IRIs still works when no domain is given", c do
    Postgrex.query!(c.pg, "CREATE TABLE IF NOT EXISTS old_likes (id bigserial PRIMARY KEY, note_iri text NOT NULL, actor_iri text NOT NULL)", [])
    Postgrex.query!(c.pg, "TRUNCATE old_likes RESTART IDENTITY", [])
    Postgrex.query!(c.pg, "INSERT INTO old_likes (note_iri, actor_iri) VALUES ($1, $2)", ["https://remote.test/n/2", "https://sukhi.test/users/alice"])
    copy_people(c)

    assert %{copied: 1, missing: []} = MigrateLikes.copy(c.db, c.pg)
    assert likers(c.db, "https://remote.test/n/2") == 1
  end
end
