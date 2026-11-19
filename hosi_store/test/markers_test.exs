defmodule MarkersTest do
  use ExUnit.Case, async: false
  @moduletag :needs_pg

  alias SukhiHosi.{Accounts, Actors, Markers, Notes, Notifications, Pg}

  setup do
    Pg.reset!(SpikePg)
    %{pg: SpikePg}
  end

  test "the first write is version 1; each next one raises it and replaces the place", %{pg: pg} do
    assert {:ok, %{version: 1}} = Markers.upsert(pg, 7, "home", "100")
    assert {:ok, %{version: 2, last_read_id: "250"}} = Markers.upsert(pg, 7, "home", "250")
    assert %{"home" => %{last_read_id: "250", version: 2}} = Markers.get(pg, 7, ["home"])
  end

  test "only the two timelines; the others are refused, and asking for one that is not there is empty", %{pg: pg} do
    assert {:error, :invalid_timeline} = Markers.upsert(pg, 7, "public", "1")
    assert %{} == Markers.get(pg, 7, ["home", "notifications", "public"])
    {:ok, _} = Markers.upsert(pg, 7, "notifications", "9")
    assert ["notifications"] = pg |> Markers.get(7, ["home", "notifications"]) |> Map.keys()
  end

  test "each person has their own; erasing one takes only theirs", %{pg: pg} do
    {:ok, _} = Markers.upsert(pg, 1, "home", "10")
    {:ok, _} = Markers.upsert(pg, 1, "notifications", "11")
    {:ok, _} = Markers.upsert(pg, 2, "home", "20")

    assert 2 = Markers.erase(pg, 1)
    assert 0 = Markers.erase(pg, 1)
    assert %{} == Markers.get(pg, 1, ["home", "notifications"])
    assert %{"home" => %{last_read_id: "20"}} = Markers.get(pg, 2, ["home"])
  end

  @tag :concurrent_pg
  test "many at once are many versions: none is lost", %{pg: pg} do
    1..20 |> Task.async_stream(&Markers.upsert(pg, 7, "home", "#{&1}"), max_concurrency: 10, timeout: 30_000) |> Stream.run()
    assert %{"home" => %{version: 20}} = Markers.get(pg, 7, ["home"])
  end

  @tag :needs_dtlv
  test "the marker and the notifications together: what is newer than the place is unread", %{pg: pg} do
    {db, _dir} = TestDb.open()
    alice = Actors.create_local(db, "alice")
    fans = for i <- 1..4, do: Actors.create_local(db, "fan#{i}")
    {:ok, n} = Notes.post(db, alice, "https://x/n/1", "hello")
    for f <- Enum.take(fans, 2), do: :ok = Notes.like(db, n, f)

    [newest | _] = Notifications.list(db, alice)
    {:ok, _} = Markers.upsert(pg, alice, "notifications", to_string(newest.id))
    for f <- Enum.drop(fans, 2), do: :ok = Notes.like(db, n, f)

    %{"notifications" => %{last_read_id: last}} = Markers.get(pg, alice, ["notifications"])
    assert 2 = Notifications.count_after(db, alice, String.to_integer(last))
    assert 4 = Notifications.count_after(db, alice, 0)

    {:ok, _} = Accounts.erase(db, alice)
    assert 1 = Markers.erase(pg, alice)
  end

  describe "mark as read" do
    test "the place only goes forward: a device that is behind cannot un-read", %{pg: pg} do
      assert {:ok, %{last_read_id: "100", version: 1, moved: true}} = Markers.advance(pg, 7, "notifications", "100")
      assert {:ok, %{last_read_id: "250", version: 2, moved: true}} = Markers.advance(pg, 7, "notifications", "250")
      assert {:ok, %{last_read_id: "250", version: 2, moved: false}} = Markers.advance(pg, 7, "notifications", "100")
      assert {:ok, %{last_read_id: "250", moved: false}} = Markers.advance(pg, 7, "notifications", "250")
      # numbers, not strings: "1000" is later than "999"
      {:ok, _} = Markers.advance(pg, 7, "home", "999")
      assert {:ok, %{last_read_id: "1000", moved: true}} = Markers.advance(pg, 7, "home", "1000")
      assert {:error, :invalid_timeline} = Markers.advance(pg, 7, "public", "1")
    end

    test "an id that is not digits is taken as it is, and does not break the next", %{pg: pg} do
      {:ok, _} = Markers.upsert(pg, 7, "home", "opaque")
      assert {:ok, %{last_read_id: "5", moved: true}} = Markers.advance(pg, 7, "home", "5")
      # digits, then something that is not: the two cannot be compared, and it must not raise
      assert {:ok, %{last_read_id: "opaque2", moved: true}} = Markers.advance(pg, 7, "home", "opaque2")
    end

    @tag :needs_dtlv
    test "read the notifications: up to the newest, nothing unread; later ones are unread again; none is :nothing", %{pg: pg} do
      {db, _dir} = TestDb.open()
      alice = Actors.create_local(db, "alice")
      fans = for i <- 1..3, do: Actors.create_local(db, "fan#{i}")
      assert :nothing = Markers.read_notifications(pg, db, alice)

      {:ok, n} = Notes.post(db, alice, "https://x/n/1", "hello")
      for f <- Enum.take(fans, 2), do: :ok = Notes.like(db, n, f)
      assert {:ok, %{moved: true, last_read_id: last}} = Markers.read_notifications(pg, db, alice)
      assert 0 = Notifications.count_after(db, alice, String.to_integer(last))
      assert {:ok, %{moved: false}} = Markers.read_notifications(pg, db, alice)

      :ok = Notes.like(db, n, List.last(fans))
      assert 1 = Notifications.count_after(db, alice, String.to_integer(last))
      assert {:ok, %{moved: true}} = Markers.read_notifications(pg, db, alice)
    end
  end
end
