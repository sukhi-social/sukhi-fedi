# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.RecordsTest do
  use CoreViews.Case

  # account ids as PostgreSQL gives them: small, and not records of hosigraph
  @alice 2
  @bob 3

  test "a note, its boost, a reaction and a follow are facts under shared names" do
    note = note!(@alice, ap_id: "https://here.test/notes/1")
    boost = boost!(@bob, note)
    {:ok, reaction} = react(@bob, note, "⭐")
    follow = follow!(@bob, @alice)

    assert %{"ap/type": [:note], "ap/attributed-to": [@alice], "hosi/owner": [@alice]} =
             Repo.facts(note)

    note_id = note.id

    assert %{"ap/type": [:announce], "ap/actor": [@bob], "ap/object": [^note_id]} =
             Repo.facts(boost)

    assert %{"ap/type": [:like], "ap/content": ["⭐"]} = Repo.facts(reaction)

    assert %{"ap/type": [:follow], "ap/actor": [@bob], "ap/object": [@alice]} =
             Repo.facts(follow)

    # each view shows its own type only
    assert [note.id] == Repo.all(from n in Note, select: n.id)
    assert [boost.id] == Repo.all(from b in Boost, select: b.id)
    assert [reaction.id] == Repo.all(from r in Reaction, select: r.id)
    assert [follow.id] == Repo.all(from f in Follow, select: f.id)
  end

  @tag :real
  test "ids are hosigraph's and sort by time" do
    before = System.system_time(:millisecond)
    a = note!(@alice)
    b = note!(@alice)

    assert a.id < b.id
    assert_in_delta DateTime.to_unix(Timelines.to_datetime(a.id), :millisecond), before, 5_000
  end

  test "one boost per actor and note; a reaction per emoji; the rules do not cross types" do
    note = note!(@alice)
    boost!(@bob, note)

    assert {:error, cs} =
             %Boost{} |> Boost.changeset(%{account_id: @bob, note_id: note.id}) |> Repo.insert()

    assert cs.errors[:account_id]

    assert {:ok, _} = react(@bob, note, "a")
    assert {:ok, _} = react(@bob, note, "b")
    assert {:error, cs} = react(@bob, note, "a")
    assert cs.errors[:account_id]
  end

  test "one follow per follower and followee" do
    follow!(@bob, @alice)

    assert {:error, cs} =
             %Follow{}
             |> Follow.changeset(%{follower_id: @bob, follower_uri: uri(@bob), followee_id: @alice})
             |> Repo.insert()

    assert cs.errors[:follower_uri]
  end

  test "a local note gets its URI after the insert; it is unique and then fixed" do
    note = note!(@alice)
    uri = "https://here.test/notes/#{note.id}"

    assert {:ok, note} = note |> Ecto.Changeset.change(ap_id: uri) |> Repo.update()
    assert Repo.get_by(Note, ap_id: uri).id == note.id

    assert_raise Ecto.Hosi.Error, fn ->
      note |> Ecto.Changeset.change(ap_id: uri <> "x") |> Repo.update()
    end

    assert {:error, cs} =
             %Note{}
             |> Note.changeset(%{account_id: @bob, content: "copy", ap_id: uri})
             |> Repo.insert()

    assert cs.errors[:ap_id]
  end

  test "a delete leaves a tombstone; boosts and reactions of the note go with it" do
    note = note!(@alice, ap_id: "https://here.test/notes/9", tags: ["x"], content: "secret")
    boost!(@bob, note)
    {:ok, _} = react(@bob, note, "a")
    keep = note!(@alice)
    kept = boost!(@bob, keep)

    {:ok, _} = Repo.delete(note)

    assert Repo.get(Note, note.id) == nil
    assert [kept.id] == Repo.all(from b in Boost, select: b.id)
    assert [] == Repo.all(Reaction)

    assert %{type: "tombstone", former_type: "note", account_id: @alice} =
             Repo.get_by(Tombstone, ap_id: "https://here.test/notes/9")

    facts = Repo.facts(note.id)
    refute Map.has_key?(facts, :"ap/content")
    refute Map.has_key?(facts, :"ap/tag")
    assert facts[:"hosi/owner"] == [@alice]
  end

  test "erasing by owner takes what a PostgreSQL account made" do
    mine = note!(@alice)
    theirs = note!(@bob)
    boost!(@alice, theirs)
    {:ok, _} = react(@alice, theirs, "a")
    my_follow = follow!(@alice, @bob)
    their_follow = follow!(@bob, @alice)
    their_boost = boost!(@bob, mine)

    Repo.erase([[:"owned-by", [:"hosi/owner"], [@alice]]])

    assert [theirs.id] == Repo.all(from n in Note, select: n.id)
    assert Repo.all(Reaction) == []
    assert Repo.get(Follow, my_follow.id) == nil

    # what a plain erase does NOT do (`erase_account` does, and needs the account in hosigraph):
    # others' records that point at what is gone, or at the account, stay
    assert Repo.get(Follow, their_follow.id)
    assert Repo.get(Boost, their_boost.id)
  end

  test "erase_account does not take a PostgreSQL account" do
    note!(@alice)
    assert {:error, :stale} = Repo.erase_account(@alice)
  end

  # `follower_id` is the owner: a follow cannot be written without the follower's account id
  test "a follow with no follower id is refused" do
    assert_raise ArgumentError, ~r/owned by its maker/, fn ->
      %Follow{}
      |> Follow.changeset(%{follower_uri: "https://far.test/users/z", followee_id: @alice})
      |> Repo.insert()
    end
  end
end
