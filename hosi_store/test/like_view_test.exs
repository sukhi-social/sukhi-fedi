defmodule LikeViewTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv

  alias SukhiHosi.{Actors, Notes}

  setup do
    {db, _dir} = TestDb.open()
    %{db: db, alice: Actors.create_local(db, "alice"), bob: Actors.create_local(db, "bob")}
  end

  test "how many like each post, and whether the viewer does; a post it does not have is not in the answer", c do
    {:ok, n1} = Notes.post(c.db, c.alice, "https://x/n/1", "one")
    {:ok, _} = Notes.post(c.db, c.alice, "https://x/n/2", "two")
    :ok = Notes.like(c.db, n1, c.bob)
    :ok = Notes.like(c.db, n1, c.alice)

    iris = ["https://x/n/1", "https://x/n/2", "https://x/n/ghost"]

    assert %{
             "https://x/n/1" => %{count: 2, mine: true},
             "https://x/n/2" => %{count: 0, mine: false}
           } == Notes.like_view(c.db, iris, Actors.iri(c.db, c.bob))
  end

  test "no viewer, or one hosigraph does not know, likes nothing", c do
    {:ok, n1} = Notes.post(c.db, c.alice, "https://x/n/1", "one")
    :ok = Notes.like(c.db, n1, c.bob)

    assert %{"https://x/n/1" => %{count: 1, mine: false}} == Notes.like_view(c.db, ["https://x/n/1"])
    assert %{"https://x/n/1" => %{count: 1, mine: false}} == Notes.like_view(c.db, ["https://x/n/1"], "https://nowhere/users/x")
  end

  test "a like taken back is gone from both the count and the viewer's flag; asking for nothing asks nothing", c do
    {:ok, n1} = Notes.post(c.db, c.alice, "https://x/n/1", "one")
    :ok = Notes.like(c.db, n1, c.bob)
    :ok = Notes.unlike(c.db, n1, c.bob)

    assert %{"https://x/n/1" => %{count: 0, mine: false}} == Notes.like_view(c.db, ["https://x/n/1"], Actors.iri(c.db, c.bob))
    assert %{} == Notes.like_view(c.db, [], Actors.iri(c.db, c.bob))
  end
end
