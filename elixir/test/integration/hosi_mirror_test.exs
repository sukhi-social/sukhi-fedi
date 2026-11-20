# SPDX-License-Identifier: AGPL-3.0-or-later

# Only in a build that has hosigraph (`SUKHI_HOSI=1`, hosi_store/): otherwise this file is empty.
if Code.ensure_loaded?(SukhiFedi.HosiMirror.Server) do
  defmodule SukhiFedi.Integration.HosiMirrorTest do
    @moduledoc """
    The people and posts that are new in the Repo are in hosigraph after a round: the same Ecto
    queries (`RepoSource`), whichever store the Repo is on.
    """

    use SukhiFedi.IntegrationCase, async: false

    import ExUnit.CaptureLog

    @moduletag :integration
    # needs the `dtlv` binary, which hosigraph runs on
    @moduletag :dtlv

    alias SukhiFedi.HosiMirror.Server
    alias SukhiFedi.Schema.{Account, Note, Reaction}
    alias SukhiHosi.{Actors, Notes}

    setup do
      dir = Path.join(System.tmp_dir!(), "hosi-mirror-#{System.unique_integer([:positive])}")
      # registered first, so it runs after ExUnit has stopped the server (and so hosigraph)
      on_exit(fn -> File.rm_rf(dir) end)
      pid = start_supervised!({Server, dir: dir, tick: :infinity, sweep_every: :timer.hours(1), domain: "sukhi.test"})

      %{db: :sys.get_state(pid).db}
    end

    test "a new person and a new post are in hosigraph after a round, and a second round has nothing to do", %{db: db} do
      alice = Repo.insert!(%Account{username: "alice"})
      bob = Repo.insert!(%Account{username: "bob", domain: "remote.test", actor_uri: "https://remote.test/users/bob"})
      Repo.insert!(%Note{account_id: alice.id, content: "hello", ap_id: "https://sukhi.test/notes/1", visibility: "public"})
      Repo.insert!(%Note{account_id: bob.id, content: "<p>hi</p>", ap_id: "https://remote.test/n/2", domain: "remote.test", visibility: "public"})

      assert %{actors: 2, notes: 2, missing: [], skipped: []} = Server.sync_now()

      assert Actors.find(db, "https://sukhi.test/users/alice")
      assert Actors.find(db, "https://remote.test/users/bob")
      assert %{html: "hello", author: author} = Notes.get(db, Notes.find(db, "https://sukhi.test/notes/1"))
      assert author == Actors.find(db, "https://sukhi.test/users/alice")

      assert %{actors: 0, notes: 0, missing: []} = Server.sync_now()

      Repo.insert!(%Note{account_id: alice.id, content: "later", ap_id: "https://sukhi.test/notes/3", visibility: "public"})
      assert %{actors: 0, notes: 1} = Server.sync_now()
    end

    test "a favourite is followed to the post it is on; another reaction is not", %{db: db} do
      alice = Repo.insert!(%Account{username: "alice"})
      bob = Repo.insert!(%Account{username: "bob", domain: "remote.test", actor_uri: "https://remote.test/users/bob"})
      note = Repo.insert!(%Note{account_id: alice.id, content: "hello", ap_id: "https://sukhi.test/notes/1", visibility: "public"})
      Repo.insert!(%Reaction{account_id: bob.id, note_id: note.id, emoji: SukhiFedi.Notes.favourite_emoji()})
      Repo.insert!(%Reaction{account_id: alice.id, note_id: note.id, emoji: "🎉"})

      assert %{likes: 1, likes_missing: []} = Server.sync_now()

      [e] = SukhiHosi.Store.entities(db, [Notes.find(db, "https://sukhi.test/notes/1")])
      assert e[:"object/liked-by"] == [Actors.find(db, "https://remote.test/users/bob")]
    end

    test "a post that left the store is taken away at the next sweep, and the others stay", %{db: db} do
      alice = Repo.insert!(%Account{username: "alice"})
      gone = Repo.insert!(%Note{account_id: alice.id, content: "bye", ap_id: "https://sukhi.test/notes/1", visibility: "public"})
      Repo.insert!(%Note{account_id: alice.id, content: "stay", ap_id: "https://sukhi.test/notes/2", visibility: "public"})
      assert %{notes: 2} = Server.sync_now()

      Repo.delete!(gone)
      assert %{gone: 1, unliked: 0} = Server.sync_now()
      assert Notes.find(db, "https://sukhi.test/notes/1") == nil
      assert Notes.find(db, "https://sukhi.test/notes/2")

      assert %{gone: 0} = Server.sync_now()
    end

    test "a favourite taken back is taken off the post at the next sweep", %{db: db} do
      alice = Repo.insert!(%Account{username: "alice"})
      bob = Repo.insert!(%Account{username: "bob", domain: "remote.test", actor_uri: "https://remote.test/users/bob"})
      note = Repo.insert!(%Note{account_id: alice.id, content: "hello", ap_id: "https://sukhi.test/notes/1", visibility: "public"})
      taken_back = Repo.insert!(%Reaction{account_id: bob.id, note_id: note.id, emoji: SukhiFedi.Notes.favourite_emoji()})
      Repo.insert!(%Reaction{account_id: alice.id, note_id: note.id, emoji: SukhiFedi.Notes.favourite_emoji()})
      assert %{likes: 2} = Server.sync_now()

      Repo.delete!(taken_back)
      assert %{gone: 0, unliked: 1} = Server.sync_now()

      [e] = SukhiHosi.Store.entities(db, [Notes.find(db, "https://sukhi.test/notes/1")])
      assert e[:"object/liked-by"] == [Actors.find(db, "https://sukhi.test/users/alice")]
    end

    test "a tick sweeps the first time and then not until the time is up; sync_now always does", %{db: db} do
      pid = GenServer.whereis(Server)
      alice = Repo.insert!(%Account{username: "alice"})
      note = Repo.insert!(%Note{account_id: alice.id, content: "bye", ap_id: "https://sukhi.test/notes/1", visibility: "public"})

      # a tick is what the timer sends; asking the state afterwards waits for it
      send(pid, :tick)
      _ = :sys.get_state(pid)
      assert Notes.find(db, "https://sukhi.test/notes/1")

      Repo.delete!(note)
      send(pid, :tick)
      _ = :sys.get_state(pid)
      # an hour has not passed: no sweep yet
      assert Notes.find(db, "https://sukhi.test/notes/1")

      assert %{gone: 1} = Server.sync_now()
      assert Notes.find(db, "https://sukhi.test/notes/1") == nil
    end

    describe "the like view, asked of hosigraph too" do
      setup do
        # the server is started by hand here, so the mirror's own switch is set too (`enabled?/0`)
        Application.put_env(:sukhi_fedi, :hosi_mirror, true)
        Application.put_env(:sukhi_fedi, :hosi_shadow, true)

        on_exit(fn ->
          Application.delete_env(:sukhi_fedi, :hosi_mirror)
          Application.delete_env(:sukhi_fedi, :hosi_shadow)
        end)
      end

      # the comparing is done in the server, a little after: asking for its state waits for that
      defp settle, do: :sys.get_state(GenServer.whereis(Server))

      defp people_and_post do
        alice = Repo.insert!(%Account{username: "alice"})
        bob = Repo.insert!(%Account{username: "bob", domain: "remote.test", actor_uri: "https://remote.test/users/bob"})
        note = Repo.insert!(%Note{account_id: alice.id, content: "hello", ap_id: "https://sukhi.test/notes/1", visibility: "public"})
        {bob, note}
      end

      defp favourite(account, note),
        do: Repo.insert!(%Reaction{account_id: account.id, note_id: note.id, emoji: SukhiFedi.Notes.favourite_emoji()})

      # what the page shows: the count, and whether `viewer` favourited, as the store says
      defp view(viewer, note) do
        {SukhiFedi.Notes.counts_for_notes([note.id])[note.id].favourites,
         SukhiFedi.Notes.viewer_flags_many(viewer.id, [note.id])[note.id].favourited}
      end

      test "when they agree there is nothing to say, and the answer is the store's" do
        {bob, note} = people_and_post()
        favourite(bob, note)
        Server.sync_now()

        log = capture_log(fn -> assert {1, true} = view(bob, note); settle() end)
        refute log =~ "like shadow"
      end

      test "a favourite not followed yet is a difference, told by kind and way, without a post's id" do
        {bob, note} = people_and_post()
        Server.sync_now()
        favourite(bob, note)

        log = capture_log(fn -> assert {1, true} = view(bob, note); settle() end)
        assert log =~ "like shadow (favourites): 1 of 1 posts differ (hosigraph higher 0, lower 1)"
        assert log =~ "like shadow (favourited): 1 of 1 posts differ (hosigraph higher 0, lower 1)"

        # (the log also has Ecto's own SQL lines, which carry the values)
        shadow = log |> String.split("\n") |> Enum.filter(&(&1 =~ "like shadow")) |> Enum.join("\n")
        refute shadow =~ note.ap_id
        refute shadow =~ Integer.to_string(note.id)
      end

      test "a favourite taken back and not swept yet is hosigraph higher" do
        {bob, note} = people_and_post()
        like = favourite(bob, note)
        Server.sync_now()
        Repo.delete!(like)

        log = capture_log(fn -> assert {0, false} = view(bob, note); settle() end)
        assert log =~ "like shadow (favourites): 1 of 1 posts differ (hosigraph higher 1, lower 0)"
        assert log =~ "like shadow (favourited): 1 of 1 posts differ (hosigraph higher 1, lower 0)"
      end

      test "a post hosigraph does not have is counted apart from a difference" do
        {bob, note} = people_and_post()

        log = capture_log(fn -> assert {0, false} = view(bob, note); settle() end)
        assert log =~ "like shadow (favourites): 0 of 1 posts differ (hosigraph higher 0, lower 0), 1 not in hosigraph"
      end

      test "nobody looking is not asked about" do
        {_bob, note} = people_and_post()
        Server.sync_now()

        log = capture_log(fn -> assert %{} = SukhiFedi.Notes.viewer_flags_many(nil, [note.id]); settle() end)
        refute log =~ "like shadow"
      end

      test "a server that is behind drops the notes instead of piling them up" do
        {bob, note} = people_and_post()
        Server.sync_now()
        favourite(bob, note)
        pid = GenServer.whereis(Server)
        answer = %{note.id => %{favourites: 1}}

        log =
          capture_log(fn ->
            :sys.suspend(pid)
            for _ <- 1..80, do: Server.shadow(:favourites, [[note.id]], answer)
            :sys.resume(pid)
            settle()
          end)

        # each one that was kept says that it differs (the store has 1, hosigraph 0)
        kept = length(Regex.scan(~r/like shadow \(favourites\)/, log))
        assert kept in 1..79
      end

      test "when it is not asked for, hosigraph is not asked" do
        Application.put_env(:sukhi_fedi, :hosi_shadow, false)
        {bob, note} = people_and_post()
        Server.sync_now()
        favourite(bob, note)

        log = capture_log(fn -> assert {1, true} = view(bob, note); settle() end)
        refute log =~ "like shadow"
      end
    end

    test "what hosi_store calls a favourite is what sukhi calls one" do
      assert SukhiHosi.Copy.favourite() == SukhiFedi.Notes.favourite_emoji()
    end
  end
end
