# SPDX-License-Identifier: AGPL-3.0-or-later

# Only in a build that has hosigraph (`SUKHI_HOSI=1`, hosi_store/): otherwise this file is empty.
if Code.ensure_loaded?(SukhiFedi.HosiMirror.Server) do
  defmodule SukhiFedi.Integration.HosiMirrorTest do
    @moduledoc """
    The people and posts that are new in the Repo are in hosigraph after a round: the same Ecto
    queries (`RepoSource`), whichever store the Repo is on.
    """

    use SukhiFedi.IntegrationCase, async: false

    @moduletag :integration
    # needs the `dtlv` binary, which hosigraph runs on
    @moduletag :dtlv

    alias SukhiFedi.HosiMirror.Server
    alias SukhiFedi.Schema.{Account, Note}
    alias SukhiHosi.{Actors, Notes}

    setup do
      dir = Path.join(System.tmp_dir!(), "hosi-mirror-#{System.unique_integer([:positive])}")
      # registered first, so it runs after ExUnit has stopped the server (and so hosigraph)
      on_exit(fn -> File.rm_rf(dir) end)
      pid = start_supervised!({Server, dir: dir, tick: :infinity, domain: "sukhi.test"})

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
  end
end
