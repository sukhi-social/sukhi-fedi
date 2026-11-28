# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.TimelinesTest do
  use CoreViews.Case

  @me 2
  @friend 3
  @other 4
  @here "https://here.test/%"

  setup do
    follow!(@me, @friend)
    follow!(@me, @other, "pending")
    :ok
  end

  defp home(opts \\ []),
    do: Timelines.home(@me, uri(@me), Keyword.put_new(opts, :reply_here, @here))

  defp ids(rows), do: Enum.map(rows, & &1.id)

  test "home: my notes and accepted follows', newest first, without direct notes" do
    a = note!(@me)
    b = note!(@friend, visibility: "followers")
    note!(@friend, visibility: "direct")
    note!(@other)

    assert ids(home()) == [b.id, a.id]
    assert ids(home(exclude_self: true)) == [b.id]
    assert ids(home(hidden: [@friend])) == [a.id]
  end

  @tag :real
  test "home: boosts of public notes are interleaved by time" do
    old = DateTime.add(DateTime.utc_now(:second), -60)
    theirs = note!(@other, created_at: old)
    quiet = note!(@other, visibility: "followers", created_at: old)
    mine = note!(@me)
    Process.sleep(1100)
    boost = boost!(@friend, theirs)
    boost!(@friend, quiet)

    assert [%{boost_id: id, booster_id: @friend, note: %{id: theirs_id}}, %Note{id: mine_id} | _] =
             home()

    assert {id, theirs_id, mine_id} == {boost.id, theirs.id, mine.id}
    # `theirs` itself is not in home: its author is not followed
    assert length(home()) == 2
    assert length(home(hide_boosts: true)) == 1
    assert length(home(gates: %{hide_boosts: [@friend]})) == 1
    assert length(home(excluded: [@friend])) == 1
    assert length(home(hidden: [@friend])) == 1
  end

  test "home: the list gates" do
    plain = note!(@friend)
    media = note!(@friend, media_ids: [900, 901])
    sensitive = note!(@friend, sensitive: true)
    reply_far = note!(@friend, in_reply_to_ap_id: "https://far.test/notes/1")
    reply_here = note!(@friend, in_reply_to_ap_id: "https://here.test/notes/1")
    all = [reply_here, reply_far, sensitive, media, plain] |> ids()

    assert ids(home()) == all
    assert ids(home(gates: %{only_media: [@friend]})) == [media.id]
    assert ids(home(only_media: true)) == [media.id]
    assert ids(home(gates: %{hide_sensitive: [@friend]})) == all -- [sensitive.id]
    assert ids(home(hide_sensitive: true)) == all -- [sensitive.id]
    assert ids(home(gates: %{hide_replies: [@friend]})) == all -- [reply_here.id, reply_far.id]
    assert ids(home(gates: %{replies_to_me: [@friend]})) == all -- [reply_far.id]
    assert ids(home(excluded: [@friend])) == [reply_here.id]
  end

  test "home: the keyword gate matches the text or a tag" do
    text = note!(@friend, content: "About Elixir today")
    tagged = note!(@friend, content: "no word", tags: ["elixir"])
    note!(@friend, content: "nothing")
    mine = note!(@me, content: "nothing of mine")

    assert ids(home(keywords: [{[@friend], "#Elixir"}])) == [mine.id, tagged.id]
    assert ids(home(keywords: [{[@friend], "elixir"}])) == [mine.id, tagged.id, text.id]
  end

  @tag :real
  test "home: paging by id" do
    notes = for _ <- 1..7, do: note!(@friend)
    newest = notes |> ids() |> Enum.reverse()

    first = home(limit: 3)
    second = home(limit: 3, max_id: List.last(first).api_id)

    assert ids(first) == Enum.take(newest, 3)
    assert ids(second) == newest |> Enum.drop(3) |> Enum.take(3)
    third = Enum.find(notes, &(&1.id == Enum.at(newest, 2)))
    assert ids(home(since_id: third.api_id)) == Enum.take(newest, 2)
  end

  @tag :real
  test "home: pages by API id over local notes, remote notes and boosts" do
    old = DateTime.add(DateTime.utc_now(:second), -60)
    theirs = note!(@other, created_at: old)
    first = note!(@friend)
    far = note!(@friend, domain: "far.test", ap_id: "https://far.test/notes/2")
    Process.sleep(1100)
    boost = boost!(@friend, theirs)
    Process.sleep(1100)
    last = note!(@friend)
    all = [last.api_id, boost.api_id, far.api_id, first.api_id]

    assert Enum.map(home(), & &1.api_id) == all

    pages =
      Stream.unfold(nil, fn after_ ->
        case home(limit: 1, max_id: after_) do
          [row] -> {row.api_id, row.api_id}
          [] -> nil
        end
      end)

    assert Enum.take(pages, 10) == all

    # an undone local boost still says when it was made; an unknown remote ID says nothing
    Repo.delete!(boost)
    assert Enum.map(home(max_id: boost.api_id), & &1.api_id) == [far.api_id, first.api_id]
    assert home(max_id: CoreViews.Ids.s0kza("https://far.test/gone")) == []
    assert home(max_id: "12345") == []
  end

  test "home: asks the index again while the gates leave too few" do
    wanted = for _ <- 1..3, do: note!(@friend, media_ids: [900])
    for _ <- 1..60, do: note!(@friend)

    assert ids(home(only_media: true, limit: 3)) == wanted |> ids() |> Enum.reverse()
  end

  # the widening asks about more and more ids; unchunked, Datalevin failed to compile the query
  @tag :real
  test "home: finds nothing among many posts without failing" do
    now = DateTime.utc_now(:second)

    # a second apart: among thousands of equal times a step of the walk nears the 5 s limit (README)
    for(i <- 1..11_000, do: %{account_id: @friend, content: "n", created_at: DateTime.add(now, -i)})
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Repo.insert_all(Note, &1, timeout: 120_000))

    assert home(only_media: true) == []
  end

  # reactions share `ap/actor`; the boost index must not make the walk read them
  @tag :real
  test "home: an account's boosts are found behind many newer reactions" do
    old = DateTime.add(DateTime.utc_now(:second), -60)
    theirs = note!(@other, created_at: old)
    boost = boost!(@friend, theirs, created_at: old)
    now = DateTime.utc_now(:second)

    notes = List.duplicate(%{account_id: @other, content: "n", created_at: now}, 3_000)
    {_, rows} = Repo.insert_all(Note, notes, returning: [:id], timeout: 120_000)

    reactions =
      for %{id: id} <- rows,
          do: %{account_id: @friend, note_id: id, emoji: "a", created_at: now}

    Repo.insert_all(Reaction, reactions, timeout: 120_000)

    assert [%{boost_id: found}] = home()
    assert found == boost.id
  end

  test "public and tag: local public notes only" do
    local = note!(@friend, tags: ["x"])
    remote = note!(@other, tags: ["x"], domain: "far.test", ap_id: "https://far.test/notes/9")
    note!(@friend, visibility: "unlisted", tags: ["x"])
    gone = note!(@friend, tags: ["x"])
    {:ok, _} = Repo.delete(gone)

    assert ids(Timelines.public()) == [local.id]
    assert ids(Timelines.public(local: false)) == [remote.id, local.id]
    assert ids(Timelines.public(local: false, hidden: [@other])) == [local.id]
    assert ids(Timelines.tag("#X")) == [local.id]
    assert ids(Timelines.tag("x", local: false)) == [remote.id, local.id]
    assert Timelines.tag("y") == []
  end
end
