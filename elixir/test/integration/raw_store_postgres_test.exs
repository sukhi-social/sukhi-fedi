# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RawStore.PostgresTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.RawStore
  alias SukhiFedi.RawStore.{Config, Postgres}

  setup do
    SukhiFedi.QueueRepo.query!("DELETE FROM raw_blobs")
    %{config: %Config{inline_max: 16, grace_s: 0}}
  end

  test "round trip, dedup, and gc through the queue database", %{config: c} do
    raw = String.duplicate("k", 200)
    {:ok, %{"object/raw-ref": ref} = attrs} = RawStore.put("object", raw, c)
    {:ok, ^attrs} = RawStore.put("object", raw, c)
    assert %{rows: [[1]]} = SukhiFedi.QueueRepo.query!("SELECT count(*) FROM raw_blobs")
    assert {:ok, ^raw} = RawStore.get(attrs, "object", c)
    assert Postgres.exists?(ref, [])
    assert {:error, :missing} = Postgres.get("sha256:nope", [])

    assert {:ok, 0} = RawStore.gc([ref], c)
    assert {:ok, 1} = RawStore.gc([], c)
    refute Postgres.exists?(ref, [])
  end

  test "ensure_table is idempotent" do
    assert :ok = Postgres.ensure_table()
  end
end
