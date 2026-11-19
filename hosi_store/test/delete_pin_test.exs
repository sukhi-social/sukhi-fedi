defmodule DeletePinTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv
  @moduletag :needs_pg

  alias SukhiHosi.{Actors, Feeder, Notes, Notifications, Pg, Store, Timeline}

  setup do
    {db, _dir} = TestDb.open()
    Pg.reset!(SpikePg)
    %{db: db, pg: SpikePg, alice: Actors.create_local(db, "alice"), bob: Actors.create_local(db, "bob")}
  end

  defp rows(c, subject) do
    Feeder.run_once(c.pg, c.db, "a")
    c.pg |> Pg.outbox_rows() |> Enum.filter(&(&1.subject == subject))
  end

  describe "delete" do
    test "the post, the boosts and likes of it, and the notifications about it go; the relay is told by IRI", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      :ok = Notes.like(c.db, n, c.bob)
      :ok = Notes.boost(c.db, n, c.bob)
      assert 2 = length(Notifications.list(c.db, c.alice))

      assert :ok = Notes.delete(c.db, n, c.alice)

      assert [] = Timeline.public(c.db)
      assert [] = Notifications.list(c.db, c.alice)
      assert [] = Store.rows(c.db, "[:find ?b :where [?b :activity/type :Announce]]")
      assert nil == Notes.find(c.db, "https://x/n/1")

      assert [%{payload: %{"ap_id" => "https://x/n/1", "account_id" => a}, aggregate_id: agg}] = rows(c, "sns.outbox.note.deleted")
      assert a == c.alice and agg == to_string(n)
    end

    test "someone else's post is forbidden, a post that is not there is not found, twice is once", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      assert {:error, :forbidden} = Notes.delete(c.db, n, c.bob)
      assert {:error, :not_found} = Notes.delete(c.db, 999_999_999, c.alice)
      assert {:error, :not_found} = Notes.delete(c.db, c.alice, c.alice)

      assert :ok = Notes.delete(c.db, n, c.alice)
      assert {:error, :not_found} = Notes.delete(c.db, n, c.alice)
      assert [_one] = rows(c, "sns.outbox.note.deleted")
    end

    test "what others wrote in answer stays, and so do the other posts", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      {:ok, reply} = Notes.post(c.db, c.bob, "https://x/n/2", "re", in_reply_to: n)
      {:ok, other} = Notes.post(c.db, c.alice, "https://x/n/3", "other")

      :ok = Notes.delete(c.db, n, c.alice)
      assert %{html: "re"} = Notes.get(c.db, reply)
      assert %{html: "other"} = Notes.get(c.db, other)
    end

    test "a pinned post is taken off the profile with it, without a Remove (the Delete says it all)", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      :ok = Notes.pin(c.db, n, c.alice)
      :ok = Notes.delete(c.db, n, c.alice)
      assert [] = Notes.pinned(c.db, c.alice)
      assert [] = rows(c, "sns.outbox.remove.created")
    end
  end

  describe "pin and unpin" do
    test "pinning tells the relay Add, unpinning tells it Remove, with the post's IRI", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")

      assert :ok = Notes.pin(c.db, n, c.alice)
      assert [n] == Notes.pinned(c.db, c.alice)
      assert [%{payload: %{"note_ap_id" => "https://x/n/1", "note_id" => ^n}}] = rows(c, "sns.outbox.add.created")

      assert :ok = Notes.unpin(c.db, n, c.alice)
      assert [] = Notes.pinned(c.db, c.alice)
      assert [%{payload: %{"note_ap_id" => "https://x/n/1", "account_id" => a}}] = rows(c, "sns.outbox.remove.created")
      assert a == c.alice
    end

    test "twice is once: no second line for the relay", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      assert :not_pinned = Notes.unpin(c.db, n, c.alice)
      :ok = Notes.pin(c.db, n, c.alice)
      assert :already = Notes.pin(c.db, n, c.alice)
      :ok = Notes.unpin(c.db, n, c.alice)
      assert :not_pinned = Notes.unpin(c.db, n, c.alice)

      assert [_] = rows(c, "sns.outbox.add.created")
      assert [_] = rows(c, "sns.outbox.remove.created")
    end

    test "only your own posts, and only ones that are there", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      assert {:error, :forbidden} = Notes.pin(c.db, n, c.bob)
      assert {:error, :forbidden} = Notes.unpin(c.db, n, c.bob)
      assert {:error, :not_found} = Notes.pin(c.db, 999_999_999, c.alice)
      assert [] = rows(c, "sns.outbox.add.created")
    end
  end
end
