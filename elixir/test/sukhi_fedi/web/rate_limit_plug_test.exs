# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.RateLimitPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias SukhiFedi.Web.RateLimitPlug

  setup_all do
    {:ok, _} = Application.ensure_all_started(:hammer)
    :ok
  end

  defp opts(extra \\ []) do
    RateLimitPlug.init(
      [bucket: "t#{System.unique_integer([:positive])}", limit: 2, scale_ms: 60_000] ++ extra
    )
  end

  defp hit(path, opts), do: RateLimitPlug.call(conn(:get, path), opts)

  test "denies with 429 once the window is used up" do
    o = opts()
    refute hit("/api/x", o).halted
    refute hit("/api/x", o).halted
    c = hit("/api/x", o)
    assert c.halted and c.status == 429
  end

  test "skip_prefixes are not counted, and do not use up the window" do
    o = opts(skip_prefixes: ["/static/"])
    for _ <- 1..10, do: refute(hit("/static/emojis/a.png", o).halted)
    refute hit("/api/x", o).halted
    refute hit("/api/x", o).halted
  end

  test "a path that only looks like a skipped prefix is still counted" do
    o = opts(skip_prefixes: ["/static/"])
    refute hit("/staticky", o).halted
    refute hit("/staticky", o).halted
    assert hit("/staticky", o).status == 429
  end
end
