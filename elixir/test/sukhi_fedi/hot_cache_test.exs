# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HotCacheTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.HotCache

  # `mix test --no-start` (make test-elixir) leaves the cache tables unmade.
  setup_all do
    if Process.whereis(SukhiFedi.Cache.Ets) == nil, do: start_supervised!(SukhiFedi.Cache.Ets)
    :ok
  end

  defp counted(counter), do: fn -> Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) end

  test "runs the function once within the TTL" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    key = {:hot_cache_test, make_ref()}

    assert HotCache.fetch(key, 30, counted(counter)) == 1
    assert HotCache.fetch(key, 30, counted(counter)) == 1
    assert Agent.get(counter, & &1) == 1
  end

  test "a TTL of 0 never keeps anything" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    key = {:hot_cache_test, make_ref()}

    assert HotCache.fetch(key, 0, counted(counter)) == 1
    assert HotCache.fetch(key, 0, counted(counter)) == 2
  end

  test "is switched off in the test env, so a rollback never leaves a stale answer" do
    assert HotCache.ttl(:public_timeline) == 0
    assert HotCache.ttl(:moderation_sets) == 0
  end
end
