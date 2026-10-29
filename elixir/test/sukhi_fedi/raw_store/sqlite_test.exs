# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RawStore.SQLiteTest do
  use ExUnit.Case, async: false

  alias SukhiFedi.RawStore
  alias SukhiFedi.RawStore.{Config, SQLite}

  setup do
    path = Path.join(System.tmp_dir!(), "raw_blobs_#{System.unique_integer([:positive])}.db")
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    start_supervised!({SukhiFedi.QueueRepo, database: path, pool_size: 1})
    :ok = SQLite.ensure_table()
    on_exit(fn -> File.rm(path) end)
    %{config: %Config{inline_max: 16, grace_s: 0}}
  end

  test "round trip, dedup, and gc through the queue file", %{config: c} do
    raw = String.duplicate("k", 200)
    {:ok, %{"object/raw-ref": ref} = attrs} = RawStore.put("object", raw, c)
    {:ok, ^attrs} = RawStore.put("object", raw, c)
    assert %{rows: [[1]]} = SukhiFedi.QueueRepo.query!("SELECT count(*) FROM raw_blobs")
    assert {:ok, ^raw} = RawStore.get(attrs, "object", c)
    assert SQLite.exists?(ref, [])
    assert {:error, :missing} = SQLite.get("sha256:nope", [])

    assert {:ok, 0} = RawStore.gc([ref], c)
    assert {:ok, 1} = RawStore.gc([], c)
    refute SQLite.exists?(ref, [])
  end

  test "ensure_table is idempotent" do
    assert :ok = SQLite.ensure_table()
  end
end
