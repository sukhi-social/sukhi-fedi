# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule FloodTest do
  use ExUnit.Case, async: true

  alias PullFederation.Flood

  describe "forged notifications" do
    setup do
      {:ok, rows: Map.new(Flood.fake_notifications(), &{&1.attack, &1})}
    end

    defp row(rows, prefix) do
      rows |> Map.values() |> Enum.find(&String.starts_with?(&1.attack, prefix))
    end

    test "malformed and oversize payloads change nothing", %{rows: rows} do
      for prefix <- ["malformed", "oversize"] do
        r = row(rows, prefix)
        assert r.accepted == 0 and r.pulls_caused == 0 and r.state_growth == 0
      end
    end

    test "invented origins are refused before any state is touched", %{rows: rows} do
      r = row(rows, "10000 notifications from")
      assert r.accepted == 0 and r.state_growth == 0
    end

    test "unfollowed actors from a known origin cause no pull", %{rows: rows} do
      r = row(rows, "1,000 actors")
      assert r.accepted == 0 and r.pulls_caused == 0
      assert r.state_growth <= 2
    end

    test "a flood from a known origin is cut to one accepted notification per second", %{
      rows: rows
    } do
      r = row(rows, "10000 forged-token")
      assert r.sent == 10_000
      assert r.accepted <= 11 and r.pulls_caused <= 11
      assert r.delivered_events == 1
      assert r.state_growth <= 2
    end

    test "a forged ordered token neither poisons the cursor nor hides the next real update",
         %{rows: rows} do
      r = row(rows, "forged ordered")
      refute r.cursor_poisoned
      assert r.real_update_seen
    end

    test "forged bucket versions only ask for buckets the receiver follows", %{rows: rows} do
      r = row(rows, "bucket versions")
      assert r.buckets_fetched == 1
    end
  end

  describe "stampede" do
    test "appointments converge everyone with about two requests each" do
      r = Flood.stampede(domains: 500, reserve_ms: 300_000)
      assert r.converged == "500/500"
      assert r.peak_active_streams <= 8
      assert r.pull_requests_at_origin < 500 * 2.5
    end

    test "guessing a backoff costs several times more requests and converges later" do
      guess = Flood.stampede(domains: 500, reserve_ms: 0)
      appt = Flood.stampede(domains: 500)
      assert guess.pull_requests_at_origin > 1.5 * appt.pull_requests_at_origin
      assert guess.p50_converged_ms > 1.5 * appt.p50_converged_ms
    end

    test "synchronised receivers (no jitter) do not converge by guessing" do
      r = Flood.stampede(domains: 500, reserve_ms: 0, jitter: :none, horizon_ms: 300_000)
      [n, _] = r.converged |> String.split("/") |> Enum.map(&String.to_integer/1)
      assert n < 500
    end

    test "lazy start on the receiver side flattens the first second" do
      eager = Flood.stampede(domains: 500)
      lazy = Flood.stampede(domains: 500, lazy_spread_ms: 30_000)
      assert lazy.peak_requests_per_s * 5 < eager.peak_requests_per_s
      assert lazy.converged == "500/500"
    end

    test "receivers that ignore the decline cannot exceed the stream slots" do
      r = Flood.stampede(domains: 300, hammer: true, horizon_ms: 60_000)
      assert r.peak_active_streams <= 8
      # ... but they do cost the origin a request per 100 ms each
      assert r.pull_requests_at_origin > 20 * 300
    end

    test "a long RTT does not disturb appointments when the receiver subtracts it" do
      near = Flood.stampede(domains: 500)
      far = Flood.stampede(domains: 500, rtt_ms: 3_000)
      assert far.converged == "500/500"
      assert far.pull_requests_at_origin < 1.2 * near.pull_requests_at_origin
    end

    test "without the subtraction an RTT beyond the grace period loses every slot" do
      lost = Flood.stampede(domains: 200, rtt_ms: 3_000, compensate: false)
      [n, _] = lost.converged |> String.split("/") |> Enum.map(&String.to_integer/1)
      assert n < 20
    end

    test "an RTT inside the grace period is tolerated even without the subtraction" do
      r = Flood.stampede(domains: 200, rtt_ms: 600, compensate: false)
      assert r.converged == "200/200"
    end
  end
end
