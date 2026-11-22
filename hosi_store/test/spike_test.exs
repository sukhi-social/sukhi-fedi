# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SpikeTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv

  alias SukhiHosi.{Actors, Notes, Outbox}

  setup do
    {db, dir} = TestDb.open()
    %{db: db, dir: dir, alice: Actors.create_local(db, "alice"), bob: Actors.create_local(db, "bob")}
  end

  test "a post is the note and its Create line, together", %{db: db, alice: alice} do
    {:ok, n} = Notes.post(db, alice, "https://x/n/1", "hello")
    assert %{html: "hello", author: ^alice, likes: 0} = Notes.get(db, n)
    assert [%{kind: "Create", note: ^n, actor: ^alice}] = Outbox.after_id(db, 0)
  end

  test "a post that is refused leaves no line behind (all or none)", %{db: db, alice: alice} do
    {:ok, _} = Notes.post(db, alice, "https://x/n/1", "one")
    assert {:error, :duplicate} = Notes.post(db, alice, "https://x/n/1", "again")
    assert [%{kind: "Create"}] = Outbox.after_id(db, 0)
  end

  test "like twice is once, and tells the relay once; unlike undoes it", %{db: db, alice: alice, bob: bob} do
    {:ok, n} = Notes.post(db, alice, "https://x/n/1", "hello")
    assert :ok = Notes.like(db, n, bob)
    assert :already = Notes.like(db, n, bob)
    assert Notes.get(db, n).likes == 1
    assert ["Create", "Like"] = db |> Outbox.after_id(0) |> Enum.map(& &1.kind)

    assert :ok = Notes.unlike(db, n, bob)
    assert :not_liked = Notes.unlike(db, n, bob)
    assert Notes.get(db, n).likes == 0
  end

  # A like now reads the note's author before it writes (to tell them), and dtlv fails when a read
  # overlaps a write; on the JVM khana this is fine.
  @tag :concurrent_read
  test "many likes at once are all counted: there is no counter to lose", %{db: db, alice: alice} do
    {:ok, n} = Notes.post(db, alice, "https://x/n/1", "hello")
    fans = for i <- 1..20, do: Actors.create_local(db, "fan#{i}")

    fans |> Task.async_stream(&Notes.like(db, n, &1), max_concurrency: 20) |> Stream.run()
    # and the same fan pressing five times at once is still one
    for _ <- 1..5, do: Task.async(fn -> Notes.like(db, n, hd(fans)) end) |> Task.await()

    assert Notes.get(db, n).likes == 20
    assert db |> Outbox.after_id(0, 1000) |> Enum.count(&(&1.kind == "Like")) == 20
  end

  test "the relay moves on; a failed delivery is tried again, none is lost", %{db: db, alice: alice, bob: bob} do
    {:ok, n} = Notes.post(db, alice, "https://x/n/1", "hello")
    Notes.like(db, n, bob)

    assert_raise RuntimeError, fn -> Outbox.run_once(db, "deliver", fn _ -> raise "network" end) end
    assert Outbox.cursor(db, "deliver") == 0

    {:ok, seen} = Agent.start_link(fn -> [] end)
    done = Outbox.run_once(db, "deliver", fn l -> Agent.update(seen, &[l.kind | &1]) end)
    assert length(done) == 2
    assert seen |> Agent.get(& &1) |> Enum.sort() == ["Create", "Like"]

    assert Outbox.run_once(db, "deliver", fn _ -> flunk("nothing is left") end) == []
    Notes.unlike(db, n, bob)
    assert [%{kind: "Undo"}] = Outbox.run_once(db, "deliver", fn _ -> :ok end)
  end

  test "the cursor and the notes survive a restart", %{db: db, dir: dir, alice: alice} do
    {:ok, n} = Notes.post(db, alice, "https://x/n/1", "hello")
    [_] = Outbox.run_once(db, "deliver", fn _ -> :ok end)
    Hosi.stop(db)

    {:ok, db2} = TestDb.open_at(dir)
    assert Notes.get(db2, n).html == "hello"
    assert Notes.find(db2, "https://x/n/1") == n
    assert Outbox.run_once(db2, "deliver", fn _ -> flunk("already delivered") end) == []
  end

  alias SukhiHosi.Accounts

  defp all_bytes(dir) do
    dir |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)
    |> Enum.map_join(fn f -> File.read!(f) end)
  end

  test "erasing an account takes its notes and lines, and leaves other people's", %{db: db, alice: alice, bob: bob} do
    {:ok, a1} = Notes.post(db, alice, "https://x/n/a1", "alice's note")
    {:ok, b1} = Notes.post(db, bob, "https://x/n/b1", "bob's note")
    :ok = Notes.like(db, a1, bob)
    :ok = Notes.like(db, b1, alice)

    assert {:ok, _} = Accounts.erase(db, alice)

    assert Actors.find_local(db, "alice") == nil
    assert Notes.find(db, "https://x/n/a1") == nil
    assert %{html: nil} = Notes.get(db, a1)

    # bob and his note are still there, and what is left for the relay is only about bob's
    assert Actors.find_local(db, "bob") == bob
    assert %{html: "bob's note", likes: 0} = Notes.get(db, b1)
    assert [%{kind: "Create", note: ^b1, actor: ^bob}] = Outbox.after_id(db, 0)
  end

  test "after erase and clean the words are no longer on the disk", %{db: db, dir: dir, alice: alice, bob: bob} do
    {:ok, _} = Notes.post(db, alice, "https://x/n/a1", "needle-in-alices-note")
    {:ok, _} = Notes.post(db, bob, "https://x/n/b1", "bobs-note-stays")
    assert all_bytes(dir) =~ "needle-in-alices-note"

    {:ok, _} = Accounts.erase(db, alice)
    Hosi.stop(db)

    bytes = all_bytes(dir)
    refute bytes =~ "needle-in-alices-note"
    refute bytes =~ "alice"
    assert bytes =~ "bobs-note-stays"
  end
end
