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
      extra ++ [bucket: "t#{System.unique_integer([:positive])}", limit: 2, scale_ms: 60_000]
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

  test "the 429 body carries retry_after, matching the header" do
    o = opts()
    for _ <- 1..2, do: hit("/api/x", o)
    c = hit("/api/x", o)
    assert [secs] = Plug.Conn.get_resp_header(c, "retry-after")

    assert %{"error" => "rate_limited", "kind" => "limit", "retry_after" => n} =
             JSON.decode!(c.resp_body)

    refute Map.has_key?(JSON.decode!(c.resp_body), "reason")
    assert Integer.to_string(n) == secs
  end

  test "skip_if leaves matching requests uncounted, others still limited" do
    o = opts(skip_if: &(&1.request_path == "/shell"))
    for _ <- 1..10, do: refute(hit("/shell", o).halted)
    refute hit("/api/x", o).halted
    refute hit("/api/x", o).halted
    assert hit("/api/x", o).status == 429
  end

  describe "slowing down and the penalty box" do
    defp conn_from(ip),
      do: conn(:get, "/api/x") |> Plug.Conn.put_req_header("cf-connecting-ip", ip)

    defp from(ip, opts), do: RateLimitPlug.call(conn_from(ip), opts)

    test "past the soft line the answer asks the client to slow down, before any 429" do
      o = opts(limit: 10, soft: 0.5)
      ip = "198.51.100.#{System.unique_integer([:positive])}"

      quiet = for _ <- 1..5, do: from(ip, o)
      assert Enum.all?(quiet, &(Plug.Conn.get_resp_header(&1, "x-slow-down") == []))

      c = from(ip, o)
      refute c.halted
      assert [secs] = Plug.Conn.get_resp_header(c, "x-slow-down")
      assert String.to_integer(secs) in 1..60
    end

    test "a peer that keeps getting 429s is put in the penalty box, and only that peer" do
      o = opts(limit: 1, strikes: 3, ban_ms: 60_000)
      noisy = "198.51.100.#{System.unique_integer([:positive])}"
      other = "198.51.100.#{System.unique_integer([:positive])}"

      assert from(noisy, o).status == nil
      # three denials (the limit) are three strikes; the fourth would exceed them
      for _ <- 1..4, do: assert(from(noisy, o).status == 429)

      boxed = from(noisy, o)
      assert boxed.status == 429
      assert {:ok, %{"retry_after" => n} = body} = JSON.decode(boxed.resp_body)
      assert %{"kind" => "penalty", "reason" => "おいたはダメだよ〜"} = body
      assert n in 1..60

      # someone else, a different address, is untouched
      refute from(other, o).halted
    end

    test "without :strikes there is no penalty box" do
      o = opts(limit: 1)
      ip = "198.51.100.#{System.unique_integer([:positive])}"
      for _ <- 1..50, do: from(ip, o)
      assert from(ip, o).status == 429
      assert [retry] = Plug.Conn.get_resp_header(from(ip, o), "retry-after")
      assert retry == "60"
    end
  end
end
