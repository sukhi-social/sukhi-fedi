# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.BackupTest do
  # Not async: it reads the intake state for the info file.
  use ExUnit.Case, async: false

  alias SukhiFedi.Datalevin.Config
  alias SukhiFedi.Maintenance.Backup

  setup do
    tmp = Path.join(System.tmp_dir!(), "backup-#{System.unique_integer([:positive])}")
    data = Path.join(tmp, "data")
    File.mkdir_p!(data)
    File.write!(Path.join(data, "data.mdb"), String.duplicate("x", 2048))
    File.write!(Path.join(data, ".sukhi-store.json"), ~s({"format":1}))
    on_exit(fn -> File.rm_rf!(tmp) end)

    # The "dtlv": `copy` fills the destination, `stat` just answers.
    {:ok, calls} = Agent.start_link(fn -> [] end)

    cmd = fn exe, args ->
      Agent.update(calls, &[{exe, args} | &1])

      cond do
        "copy" in args ->
          dst = List.last(args)
          File.mkdir_p!(dst)
          File.write!(Path.join(dst, "data.mdb"), "copied")
          {"", 0}

        "stat" in args ->
          {"entries: 1", 0}
      end
    end

    base = [
      root: Path.join(tmp, "backups"),
      datalevin?: true,
      # `sh` is any executable that exists: the fake `cmd` never runs it.
      config: %Config{dir: data, bin: "sh", xmx: "96m"},
      graph_dir: nil,
      queue_dbs: [],
      cmd: cmd,
      free_bytes: fn _ -> :unknown end,
      manifest: fn path -> File.write(path, ~s({"format":1})) end,
      now: fn -> ~U[2026-11-05 10:20:30Z] end
    ]

    {:ok, tmp: tmp, data: data, base: base, calls: calls}
  end

  defp calls(agent), do: agent |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&elem(&1, 1))

  describe "run/1" do
    test "not on Postgres: that has its own dump", %{base: base} do
      assert {:error, :not_datalevin} = Backup.run(Keyword.put(base, :datalevin?, false))
    end

    test "copies the data directory, checks the copy opens, and names it by its time", %{
      tmp: tmp,
      base: base,
      calls: calls
    } do
      assert {:ok, %{dir: dir, items: [item], bytes: bytes}} = Backup.run(base)

      assert dir == Path.join([tmp, "backups", "20261105T102030Z"])
      assert item == %{kind: :datalevin, path: "datalevin", bytes: bytes - 0}
      assert File.read!(Path.join(dir, "datalevin/data.mdb")) == "copied"
      assert File.read!(Path.join(dir, "datalevin/.sukhi-store.json")) == ~s({"format":1})

      # copy first, then stat on the *copy*; -Xmx goes before the subcommand
      assert [
               ["-Xmx96m", "-d", _src, "copy", copied],
               ["-Xmx96m", "-d", copied, "stat"]
             ] = calls(calls)

      # the copy is built, and read back, under .partial; the rename comes last
      assert copied == Path.join(dir <> ".partial", "datalevin")

      info = dir |> Path.join("backup-info.json") |> File.read!() |> JSON.decode!()
      assert %{"store" => "datalevin", "items" => [%{"kind" => "datalevin"}]} = info
      assert File.regular?(Path.join(dir, "backup-manifest.json"))

      # complete means renamed: nothing is left half-built
      assert File.ls!(Path.join(tmp, "backups")) == ["20261105T102030Z"]
    end

    test "the graph env is copied beside it, nested as it is on disk", %{
      tmp: tmp,
      data: data,
      base: base
    } do
      graph = Path.join(data, "graph")
      File.mkdir_p!(graph)

      assert {:ok, %{dir: dir, items: items}} = Backup.run(Keyword.put(base, :graph_dir, graph))

      assert Enum.map(items, &{&1.kind, &1.path}) ==
               [{:datalevin, "datalevin"}, {:datalevin_graph, "datalevin/graph"}]

      assert File.read!(Path.join(dir, "datalevin/graph/data.mdb")) == "copied"
      assert dir =~ tmp
    end

    test "a copy that fails leaves nothing that looks like a backup", %{tmp: tmp, base: base} do
      failing = Keyword.put(base, :cmd, fn _exe, _args -> {"LMDB: no space\n", 1} end)

      assert {:error, {:dtlv_copy, 1, "LMDB: no space"}} = Backup.run(failing)
      assert File.ls!(Path.join(tmp, "backups")) == []
    end

    test "a copy that does not open is a failed backup", %{tmp: tmp, base: base} do
      cmd = fn _exe, args ->
        cond do
          "copy" in args ->
            File.mkdir_p!(List.last(args))
            {"", 0}

          "stat" in args ->
            {"MDB_INVALID", 1}
        end
      end

      assert {:error, {:dtlv_stat, 1, "MDB_INVALID"}} = Backup.run(Keyword.put(base, :cmd, cmd))
      assert File.ls!(Path.join(tmp, "backups")) == []
    end

    test "no dtlv on the PATH is said plainly", %{base: base} do
      config = %Config{dir: base[:config].dir, bin: "dtlv-that-does-not-exist"}

      assert {:error, {:dtlv_not_found, "dtlv-that-does-not-exist"}} =
               Backup.run(Keyword.put(base, :config, config))
    end

    test "refuses when the volume cannot hold it, before copying anything", %{
      base: base,
      calls: calls
    } do
      small = Keyword.put(base, :free_bytes, fn _ -> 100 end)

      assert {:error, {:no_space, %{need: need, free: 100}}} = Backup.run(small)
      assert need > 2048
      assert calls(calls) == []
    end

    test "a volume that cannot be read does not stop the backup", %{base: base} do
      assert {:ok, _} = Backup.run(Keyword.put(base, :free_bytes, fn _ -> :unknown end))
    end

    test "a second backup in the same second does not overwrite the first", %{base: base} do
      assert {:ok, %{dir: dir}} = Backup.run(base)
      assert {:error, {:exists, ^dir}} = Backup.run(base)
      assert File.dir?(dir)
    end

    test "only one at a time", %{base: base} do
      parent = self()

      cmd = fn _exe, args ->
        if "copy" in args do
          # a different process asks while this one is inside
          inner = Task.async(fn -> Backup.run(Keyword.put(base, :root, base[:root] <> "-2")) end)
          send(parent, {:inner, Task.await(inner)})
          File.mkdir_p!(List.last(args))
        end

        {"", 0}
      end

      assert {:ok, _} = Backup.run(Keyword.put(base, :cmd, cmd))
      assert_received {:inner, {:error, :already_running}}
    end
  end

  describe "SQLite queues" do
    test "VACUUM INTO and quick_check on a real file", %{tmp: tmp, base: base} do
      src = Path.join(tmp, "queue.db")
      {:ok, conn} = Exqlite.Sqlite3.open(src)

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "CREATE TABLE oban_jobs (id INTEGER PRIMARY KEY, state TEXT)"
        )

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "INSERT INTO oban_jobs (state) VALUES ('available'), ('completed')"
        )

      Exqlite.Sqlite3.close(conn)

      # the suite runs with --no-start
      {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
      start_supervised!({SukhiFedi.QueueRepo, database: src, pool_size: 1})

      opts =
        Keyword.merge(base,
          queue_dbs: [{SukhiFedi.QueueRepo, src}],
          vacuum: &Backup.vacuum_into/2
        )

      assert {:ok, %{dir: dir, items: items}} = Backup.run(opts)
      assert %{kind: :sqlite, path: "queue.db"} = Enum.find(items, &(&1.kind == :sqlite))

      {:ok, copy} = Exqlite.Sqlite3.open(Path.join(dir, "queue.db"), mode: :readonly)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(copy, "SELECT count(*) FROM oban_jobs")
      assert {:ok, [[2]]} = Exqlite.Sqlite3.fetch_all(copy, stmt)
      Exqlite.Sqlite3.release(copy, stmt)
      Exqlite.Sqlite3.close(copy)
    end

    test "quick_check says ok to a database and an error to a damaged one", %{tmp: tmp} do
      good = Path.join(tmp, "good.db")
      {:ok, conn} = Exqlite.Sqlite3.open(good)
      :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE t (a INTEGER)")
      Exqlite.Sqlite3.close(conn)
      assert Backup.quick_check(good) == :ok

      bad = Path.join(tmp, "bad.db")
      File.write!(bad, String.duplicate("not sqlite at all, ", 400))
      assert {:error, _} = Backup.quick_check(bad)
    end

    test "a queue file that does not check out fails the backup and cleans up", %{
      tmp: tmp,
      base: base
    } do
      opts =
        Keyword.merge(base,
          queue_dbs: [{SukhiFedi.QueueRepo, Path.join(tmp, "queue.db")}],
          vacuum: fn _repo, dest ->
            File.write!(dest, "junk")
            :ok
          end,
          quick_check: fn _ -> {:error, :damaged} end
        )

      assert {:error, {:sqlite, "queue.db", :damaged}} = Backup.run(opts)
      assert File.ls!(Path.join(tmp, "backups")) == []
    end
  end

  describe "prune/2" do
    test "keeps the newest complete ones, and touches nothing that is not ours", %{tmp: tmp} do
      root = Path.join(tmp, "keep")

      for stamp <- ~w(20261101T000000Z 20261102T000000Z 20261103T000000Z 20261104T000000Z) do
        File.mkdir_p!(Path.join(root, stamp))
        File.write!(Path.join([root, stamp, "backup-info.json"]), "{}")
      end

      # not ours: a stamp-shaped directory without our info file, and other names
      File.mkdir_p!(Path.join(root, "20261001T000000Z"))
      File.mkdir_p!(Path.join(root, "photos"))
      File.write!(Path.join(root, "notes.txt"), "hi")
      # a crashed run's leftover
      File.mkdir_p!(Path.join(root, "20261105T000000Z.partial"))

      removed = Backup.prune(root, 2)

      assert Enum.sort(removed) ==
               ["20261101T000000Z", "20261102T000000Z", "20261105T000000Z.partial"]

      assert root |> File.ls!() |> Enum.sort() ==
               ["20261001T000000Z", "20261103T000000Z", "20261104T000000Z", "notes.txt", "photos"]
    end

    test "keep: nil keeps every complete backup", %{tmp: tmp} do
      root = Path.join(tmp, "all")
      File.mkdir_p!(Path.join(root, "20261101T000000Z"))
      File.write!(Path.join([root, "20261101T000000Z", "backup-info.json"]), "{}")

      assert Backup.prune(root, nil) == []
    end

    test "a root that does not exist is nothing to prune", %{tmp: tmp} do
      assert Backup.prune(Path.join(tmp, "nope"), 3) == []
    end

    test "run/1 prunes after a good backup and reports what it removed", %{tmp: tmp, base: base} do
      root = base[:root]

      for stamp <- ~w(20261101T000000Z 20261102T000000Z) do
        File.mkdir_p!(Path.join(root, stamp))
        File.write!(Path.join([root, stamp, "backup-info.json"]), "{}")
      end

      assert {:ok, %{pruned: ["20261101T000000Z"]}} = Backup.run(Keyword.put(base, :keep, 2))
      assert File.ls!(root) |> Enum.sort() == ["20261102T000000Z", "20261105T102030Z"]
      assert tmp
    end
  end
end
