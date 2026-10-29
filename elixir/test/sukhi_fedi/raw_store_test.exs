# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RawStoreTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.RawStore
  alias SukhiFedi.RawStore.{Config, S3}

  defmodule Mem do
    @behaviour SukhiFedi.RawStore.Backend
    def put(k, b, o),
      do: Agent.update(o[:agent], &Map.put(&1, k, {b, o[:now] || System.os_time(:second)})) && :ok

    def get(k, o),
      do:
        with({b, _} <- Agent.get(o[:agent], &Map.get(&1, k)) || {:error, :missing}, do: {:ok, b})

    def exists?(k, o), do: Agent.get(o[:agent], &Map.has_key?(&1, k))
    def delete(k, o), do: Agent.update(o[:agent], &Map.delete(&1, k))

    def list_older_than(t, o),
      do: {:ok, Agent.get(o[:agent], fn m -> for {k, {_, at}} <- m, at <= t, do: k end)}
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{} end)

    %{
      config: %Config{
        backend: Mem,
        backend_opts: [agent: agent, now: 0],
        inline_max: 16,
        grace_s: 10
      },
      agent: agent
    }
  end

  test "a small original stays on the entity", %{config: c, agent: a} do
    assert {:ok, %{"object/raw": "{\"a\":1}"} = attrs} = RawStore.put("object", "{\"a\":1}", c)
    assert 1 = map_size(attrs)
    assert %{} == Agent.get(a, & &1)
    assert {:ok, "{\"a\":1}"} = RawStore.get(attrs, "object", c)
  end

  test "a large one becomes a pointer, and reads back", %{config: c} do
    raw = String.duplicate("x", 100)

    assert {:ok, %{"object/raw-ref": "sha256:" <> _ = ref, "object/raw-size": 100} = attrs} =
             RawStore.put("object", raw, c)

    refute Map.has_key?(attrs, :"object/raw")
    assert ref == RawStore.ref(raw)
    assert {:ok, ^raw} = RawStore.get(attrs, "object", c)
  end

  test "the same original is one blob", %{config: c, agent: a} do
    raw = String.duplicate("y", 100)
    {:ok, _} = RawStore.put("object", raw, c)
    {:ok, _} = RawStore.put("activity", raw, c)
    assert 1 = Agent.get(a, &map_size/1)
  end

  test "a damaged blob is corrupt, not accepted", %{config: c, agent: a} do
    raw = String.duplicate("z", 100)
    {:ok, %{"object/raw-ref": ref} = attrs} = RawStore.put("object", raw, c)
    Agent.update(a, &Map.put(&1, ref, {"not zstd", 0}))
    assert {:error, :corrupt} = RawStore.get(attrs, "object", c)

    other = :zstd.compress("something else") |> IO.iodata_to_binary()
    Agent.update(a, &Map.put(&1, ref, {other, 0}))
    assert {:error, :corrupt} = RawStore.get(attrs, "object", c)
  end

  test "an entity with neither is missing", %{config: c} do
    assert {:error, :missing} = RawStore.get(%{}, "object", c)
  end

  test "gc removes only unreferenced blobs past the grace period", %{config: c, agent: a} do
    {:ok, %{"object/raw-ref": kept}} = RawStore.put("object", String.duplicate("a", 100), c)
    {:ok, %{"object/raw-ref": lost}} = RawStore.put("object", String.duplicate("b", 100), c)
    young = RawStore.ref("young")
    Agent.update(a, &Map.put(&1, young, {"z", System.os_time(:second)}))

    assert {:ok, 1} = RawStore.gc([kept], c)
    assert Mem.exists?(kept, c.backend_opts)
    refute Mem.exists?(lost, c.backend_opts)
    assert Mem.exists?(young, c.backend_opts)
  end

  describe "Config.from_env/1" do
    test "defaults" do
      assert {:ok, %Config{backend: SukhiFedi.RawStore.SQLite, inline_max: 4096, grace_s: 86_400}} =
               Config.from_env(%{})
    end

    test "s3 takes its bucket from SUKHI_RAW_BUCKET, then S3_BUCKET" do
      assert {:ok, %Config{backend: S3, backend_opts: [bucket: "r"]}} =
               Config.from_env(%{
                 "SUKHI_RAW_BACKEND" => "s3",
                 "SUKHI_RAW_BUCKET" => "r",
                 "S3_BUCKET" => "m"
               })

      assert {:ok, %Config{backend_opts: [bucket: "m"]}} =
               Config.from_env(%{"SUKHI_RAW_BACKEND" => "s3", "S3_BUCKET" => "m"})
    end

    test "bad values are refused" do
      assert {:error, _} = Config.from_env(%{"SUKHI_RAW_BACKEND" => "ftp"})
      assert {:error, _} = Config.from_env(%{"SUKHI_RAW_INLINE_MAX" => "-1"})
    end
  end

  test "s3 keys are sharded by the first two hex digits" do
    assert "raw/sha256/ab/abcd" = S3.object_key("sha256:abcd")
  end
end
