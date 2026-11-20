# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule TimelineTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv

  alias SukhiHosi.{Actors, Follows, Notes, Store, Timeline}

  @us 1_000_000

  setup do
    {db, _dir} = TestDb.open()
    %{db: db, alice: Actors.create_local(db, "alice"), bob: Actors.create_local(db, "bob")}
  end

  defp post(db, who, n, opts \\ []),
    do: elem(Notes.post(db, who, "https://x/#{who}/#{n}", "post #{n}", opts), 1)

  test "public: newest first, pages by id, local filter, and only what is public", %{db: db, alice: a, bob: b} do
    ids = for n <- 1..5, do: post(db, a, n)
    _hidden = post(db, a, 6, visibility: :followers)
    _direct = post(db, b, 7, visibility: :direct)
    remote = elem(Notes.post(db, b, "https://far/1", "far", local?: false), 1)

    page1 = Timeline.public(db, limit: 3)
    assert Enum.map(page1, & &1.html) == ["far", "post 5", "post 4"]
    page2 = Timeline.public(db, limit: 3, before: List.last(page1).id)
    assert Enum.map(page2, & &1.html) == ["post 3", "post 2", "post 1"]
    assert Timeline.public(db, limit: 3, before: List.last(page2).id) == []

    assert remote in Enum.map(Timeline.public(db), & &1.id)
    refute remote in Enum.map(Timeline.public(db, local: true), & &1.id)
    assert Enum.sort(Enum.map(Timeline.public(db, local: true), & &1.id)) == Enum.sort(ids)
  end

  test "author sees to what a stranger may; tag is lower-cased; thread is the whole thread oldest first", %{db: db, alice: a, bob: b} do
    root = post(db, a, 1, tags: ["Elixir"])
    _priv = post(db, a, 2, visibility: :followers)
    r1 = post(db, b, 3, in_reply_to: root)
    {:ok, r2} = Notes.post(db, a, "https://x/alice/r2", "reply to reply", in_reply_to: r1)

    assert ["reply to reply", "post 1"] = Timeline.author(db, a) |> Enum.map(& &1.html)
    refute "post 2" in Enum.map(Timeline.author(db, a), & &1.html)
    assert "post 2" in Enum.map(Timeline.author(db, a, visibilities: [:public, :followers]), & &1.html)

    assert [%{html: "post 1"}] = Timeline.tagged(db, "ELIXIR")

    assert Timeline.thread(db, r2) |> Enum.map(& &1.html) == ["post 1", "post 3", "reply to reply"]
    assert Timeline.thread(db, root) |> Enum.map(& &1.html) == ["post 1", "post 3", "reply to reply"]
  end

  test "home: own and followed posts and boosts, folded; pending follows show nothing; pages by time", %{db: db, alice: a, bob: b} do
    c = Actors.create_local(db, "carol")
    t = Store.now_us() - 1000 * @us
    b1 = post(db, b, 1, published: t + 1 * @us)
    c1 = post(db, c, 2, published: t + 2 * @us)
    a1 = post(db, a, 3, published: t + 3 * @us)

    :ok = Follows.follow(db, a, b)
    assert Enum.map(Timeline.home(db, a), & &1.id) == [a1], "a follow still pending shows nothing of bob's"
    :ok = Follows.accept(db, a, b)
    assert Enum.map(Timeline.home(db, a), & &1.id) == [a1, b1]

    # carol is not followed, but bob boosts carol's post: it appears once, when bob boosted it
    :ok = Notes.boost(db, c1, b, published: t + 10 * @us)
    home = Timeline.home(db, a)
    assert Enum.map(home, & &1.id) == [c1, a1, b1]
    assert [%{id: ^c1, via: [via]}] = Enum.filter(home, &(&1.id == c1))
    assert via == "https://local.test/users/bob"

    # bob also boosting his own post folds into one row; a second boost by bob is refused
    :ok = Notes.boost(db, b1, b, published: t + 11 * @us)
    assert :already = Notes.boost(db, b1, b)
    assert Enum.map(Timeline.home(db, a), & &1.id) == [b1, c1, a1]

    page1 = Timeline.home(db, a, limit: 2)
    page2 = Timeline.home(db, a, limit: 2, before: List.last(page1).at)
    assert Enum.map(page1 ++ page2, & &1.id) == [b1, c1, a1]

    :ok = Follows.unfollow(db, a, b)
    assert Enum.map(Timeline.home(db, a), & &1.id) == [a1]
  end

  test "author pages by id; a page short of what a stranger may see asks again, and none is lost or doubled", %{db: db, alice: a} do
    ids = for n <- 1..10, do: post(db, a, n, visibility: if(n in 3..8, do: :followers, else: :public))

    page1 = Timeline.author(db, a, limit: 3)
    assert Enum.map(page1, & &1.html) == ["post 10", "post 9", "post 2"]
    page2 = Timeline.author(db, a, limit: 3, before: List.last(page1).id)
    assert Enum.map(page2, & &1.html) == ["post 1"]
    assert [] = Timeline.author(db, a, limit: 3, before: List.last(page2).id)

    all = [:public, :unlisted, :followers]
    p1 = Timeline.author(db, a, limit: 4, visibilities: all)
    p2 = Timeline.author(db, a, limit: 4, visibilities: all, before: List.last(p1).id)
    p3 = Timeline.author(db, a, limit: 4, visibilities: all, before: List.last(p2).id)
    assert Enum.map(p1 ++ p2 ++ p3, & &1.id) == Enum.reverse(ids)
  end

  test "home, a page at a time, is home all at once (more posts and boosts than a page)", %{db: db, alice: a, bob: b} do
    c = Actors.create_local(db, "carol")
    d = Actors.create_local(db, "dave")
    t = Store.now_us() - 1000 * @us
    :ok = Follows.follow(db, a, b, state: :accepted)
    :ok = Follows.follow(db, a, c, state: :accepted)

    # posts by me, bob, carol and (unfollowed) dave, at distinct times
    posts = for n <- 1..12, do: post(db, Enum.at([a, b, c, d], rem(n, 4)), n, published: t + n * 10 * @us)
    # bob and carol boost things (their own, each other's, dave's), some later than the newest post
    for {n, who, at} <- [{4, b, 130}, {8, c, 35}, {3, c, 45}, {12, b, 60}, {1, b, 200}, {7, c, 95}, {5, b, 210}] do
      :ok = Notes.boost(db, Enum.at(posts, n - 1), who, published: t + at * @us)
    end

    whole = Timeline.home(db, a, limit: 100)
    assert length(whole) == length(Enum.uniq_by(whole, & &1.id))

    paged = pages(db, a, 3, nil, [])
    assert Enum.map(paged, & &1.id) == Enum.map(whole, & &1.id)
    assert Enum.map(paged, & &1.at) == Enum.map(whole, & &1.at)
    assert Enum.map(paged, & &1.at) == Enum.sort(Enum.map(whole, & &1.at), :desc)
  end

  test "home: boosts of one post fill the boosts a page reads, and another boost behind them is still found", %{db: db, alice: a, bob: b} do
    [c, d, e, f] = for h <- ~w(carol dave erin frank), do: Actors.create_local(db, h)
    [x, y] = for h <- ~w(xavier yuri), do: Actors.create_local(db, h)
    t = Store.now_us() - 1000 * @us
    for who <- [b, c, d, e, f], do: :ok = Follows.follow(db, a, who, state: :accepted)

    z = post(db, x, 1, published: t + 1 * @us)
    other = post(db, y, 2, published: t + 2 * @us)
    p1 = post(db, a, 3, published: t + 80 * @us)
    _p2 = post(db, a, 4, published: t + 79 * @us)
    _p3 = post(db, a, 5, published: t + 78 * @us)

    # a page of 3 reads 4 of each; the four newest boosts are all of z, and the one of `other` is behind them
    for {who, at} <- [{b, 100}, {c, 99}, {d, 98}, {e, 97}], do: :ok = Notes.boost(db, z, who, published: t + at * @us)
    :ok = Notes.boost(db, other, f, published: t + 90 * @us)

    assert Enum.map(Timeline.home(db, a, limit: 3), & &1.id) == [z, other, p1]
  end

  defp pages(db, who, limit, before, acc) do
    opts = if before, do: [limit: limit, before: before], else: [limit: limit]

    case Timeline.home(db, who, opts) do
      [] -> acc
      page -> pages(db, who, limit, List.last(page).at, acc ++ page)
    end
  end

  test "search finds words, case-insensitively, among what is public", %{db: db, alice: a} do
    {:ok, n} = Notes.post(db, a, "https://x/s/1", "A Quick Brown Fox")
    {:ok, _} = Notes.post(db, a, "https://x/s/2", "secret fox", visibility: :followers)
    assert [%{id: ^n}] = Timeline.search(db, "quick brown")
    assert [%{id: ^n}] = Timeline.search(db, "FOX")
    assert Timeline.search(db, "zebra") == []
  end

  test "a follow is made once, accepted once", %{db: db, alice: a, bob: b} do
    assert :ok = Follows.follow(db, a, b)
    assert :already = Follows.follow(db, a, b)
    assert :ok = Follows.accept(db, a, b)
    assert :not_pending = Follows.accept(db, a, b)
    assert Follows.followees(db, a) == [b]
  end
end
