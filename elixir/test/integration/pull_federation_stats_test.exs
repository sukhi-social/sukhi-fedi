# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.PullFederationStatsTest do
  use SukhiFedi.IntegrationCase, async: false
  @moduletag :integration

  alias SukhiFedi.PullFederation.Stats
  alias SukhiFedi.Web.Admin.Render
  alias SukhiShared.{Capability, PeerCapabilities, PullStats}

  setup do
    # Counters are one global table; start from empty so the assertions are exact.
    PullStats.flush(Repo)
    Repo.query!("DELETE FROM pull_stats")
    Repo.query!("DELETE FROM pull_peer_stats")
    :ok
  end

  test "bump is batched: nothing is written until the flush, and a flush empties the counters" do
    PullStats.bump("notify_sent", ms: 20, host: "a.example")
    PullStats.bump("notify_sent", ms: 80, host: "a.example")
    PullStats.bump("notify_failed", host: "a.example")
    PullStats.bump("pull_routed", n: 5)

    assert Repo.query!("SELECT count(*) FROM pull_stats").rows == [[0]]
    assert PullStats.flush(Repo) > 0

    totals = Stats.totals(1)
    assert totals["notify_sent"] == %{n: 2, sum_ms: 100, max_ms: 80}
    assert totals["notify_failed"].n == 1
    assert totals["pull_routed"].n == 5

    # Flushing again adds nothing: what was counted is not counted twice.
    PullStats.flush(Repo)
    assert Stats.totals(1)["notify_sent"].n == 2

    # And counting continues into the same hourly row.
    PullStats.bump("notify_sent", ms: 200)
    PullStats.flush(Repo)
    assert Stats.totals(1)["notify_sent"] == %{n: 3, sum_ms: 300, max_ms: 200}
  end

  test "peers are listed busiest first with their capability and breaker state" do
    PeerCapabilities.learn(Repo, %{
      "id" => "https://busy.example/users/x",
      "generator" => %{"implements" => [%{"href" => Capability.pull_federation()}]}
    })

    PullStats.bump("notify_sent", n: 7, host: "busy.example")
    PullStats.bump("pull_ok", n: 3, host: "quiet.example")
    PullStats.flush(Repo)

    Repo.query!(
      "INSERT INTO pull_peers (host, failures, last_error, notified_at) VALUES ('busy.example', 2, 'status 503', now())"
    )

    assert [busy, quiet] = Stats.peers(10)
    assert busy.host == "busy.example"
    assert busy.capable
    assert busy.counts["notify_sent"] == 7
    assert busy.notify.failures == 2
    refute quiet.capable
    assert quiet.counts["pull_ok"] == 3
  end

  test "hourly has a row for every hour of the window, empty ones included" do
    PullStats.bump("pull_ok")
    PullStats.flush(Repo)
    rows = Stats.hourly(24)
    assert length(rows) == 25
    assert Enum.sum(for r <- rows, do: Map.get(r.kinds, "pull_ok", 0)) == 1
  end

  test "gauges read the tables" do
    Repo.query!(
      "INSERT INTO pull_pending (host, actor_uri, head, received_at) VALUES ('p.example', 'https://p.example/users/a', 3, now())"
    )

    Repo.query!(
      "INSERT INTO pull_hosts (host, next_pull_at, failures) VALUES ('p.example', now(), 2)"
    )

    g = Stats.gauges()
    assert g.pending_hosts == 1 and g.pending_actors == 1
    assert g.failing_hosts == 1
    assert g.advertised
  end

  test "prune drops old buckets only" do
    Repo.query!(
      "INSERT INTO pull_stats (bucket, kind, n) VALUES (now() - interval '100 days', 'pull_ok', 1), (now(), 'pull_ok', 1)"
    )

    assert Stats.prune(90) == 1
    assert Repo.query!("SELECT count(*) FROM pull_stats").rows == [[1]]
  end

  test "the admin page renders with data, with none, and the dashboard card renders" do
    PullStats.bump("pull_routed", n: 9)
    PullStats.bump("push_routed", n: 1)
    PullStats.bump("activities_applied", n: 2, ms: 1500, host: "h.example")
    PullStats.bump("notify_failed", host: "h.example")
    PullStats.flush(Repo)

    Repo.query!(
      "INSERT INTO pull_peers (host, failures, last_error, notified_at) VALUES ('h.example', 1, '<b>x</b>', now())"
    )

    assigns = fn ->
      totals = Stats.totals(24)

      [
        hours: 24,
        d: Stats.derive(totals),
        gauges: Stats.gauges(),
        hourly: Stats.hourly(24),
        peers: Stats.peers(30)
      ]
    end

    html = Render.render_template("pull_federation/index.html.eex", assigns.())
    assert html =~ "90%"
    assert html =~ "h.example"
    # last_error is peer-controlled text and must be escaped.
    refute html =~ "<b>x</b>"
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"

    Repo.query!("DELETE FROM pull_stats")
    Repo.query!("DELETE FROM pull_peer_stats")

    assert Render.render_template("pull_federation/index.html.eex", assigns.()) =~
             "No peer has exchanged anything yet."
  end
end
