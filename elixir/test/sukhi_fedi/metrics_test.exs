# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.MetricsTest do
  # Touches the Repo and toggles the global :metrics_token, so not async.
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Plug.Test

  alias SukhiFedi.Metrics
  alias SukhiFedi.Schema.MetricSample
  alias SukhiFedi.Web.MetricsController

  defp at(unix), do: DateTime.from_unix!(unix * 1_000_000, :microsecond)

  defp insert_at(unix, attrs \\ []) do
    Repo.insert!(struct(MetricSample, [sampled_at: at(unix), cpu_percent: 1.0] ++ attrs))
  end

  defp get(path), do: conn(:get, path) |> Plug.Conn.fetch_query_params()

  defp with_bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  describe "record/0" do
    test "persists one row from the live snapshot" do
      before = Repo.aggregate(MetricSample, :count, :id)
      row = Metrics.record()
      assert %MetricSample{} = row
      assert row.cpu_percent >= 0.0
      assert %DateTime{} = row.sampled_at
      # DLQ depth rides along: nil when `oban_jobs` isn't there (the
      # delivery migrations are the delivery app's), a count otherwise.
      assert is_nil(row.outbox_dlq_depth) or is_integer(row.outbox_dlq_depth)
      assert Repo.aggregate(MetricSample, :count, :id) == before + 1
    end

    test "dlq_depth/0 is nil or a non-negative integer, never raises" do
      depth = Metrics.dlq_depth()
      assert is_nil(depth) or (is_integer(depth) and depth >= 0)
    end
  end

  describe "history/1" do
    test "returns rows in the window, oldest first" do
      insert_at(1_000, cpu_percent: 10.0)
      insert_at(2_000, cpu_percent: 20.0)
      insert_at(3_000, cpu_percent: 30.0)

      rows = Metrics.history(since: at(1_500), until: at(3_500))

      assert Enum.map(rows, & &1.cpu_percent) == [20.0, 30.0]
      assert Enum.map(rows, & &1.sampled_at) == [at(2_000), at(3_000)]
    end

    test "respects an explicit limit" do
      for s <- 1..5, do: insert_at(s)
      assert length(Metrics.history(since: at(0), until: at(10), limit: 2)) == 2
    end
  end

  describe "prune/1" do
    test "deletes rows older than the cutoff, keeps the rest" do
      old = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)
      fresh = DateTime.add(DateTime.utc_now(), -1 * 86_400, :second)
      Repo.insert!(%MetricSample{sampled_at: old, cpu_percent: 1.0})
      kept = Repo.insert!(%MetricSample{sampled_at: fresh, cpu_percent: 1.0})

      assert Metrics.prune(90) >= 1
      ids = Repo.all(MetricSample) |> Enum.map(& &1.id)
      assert kept.id in ids
    end
  end

  describe "GET /api/metrics auth" do
    setup do
      prev = Application.get_env(:sukhi_fedi, :metrics_token)
      on_exit(fn -> Application.put_env(:sukhi_fedi, :metrics_token, prev) end)
      :ok
    end

    test "404 when no token is configured (feature off)" do
      Application.put_env(:sukhi_fedi, :metrics_token, nil)
      conn = get("/api/metrics") |> MetricsController.show([])
      assert conn.status == 404
    end

    test "401 with a missing or wrong bearer" do
      Application.put_env(:sukhi_fedi, :metrics_token, "secret-token")

      assert get("/api/metrics") |> MetricsController.show([]) |> Map.get(:status) == 401

      assert get("/api/metrics")
             |> with_bearer("nope")
             |> MetricsController.show([])
             |> Map.get(:status) == 401
    end

    test "200 live snapshot with the right bearer" do
      Application.put_env(:sukhi_fedi, :metrics_token, "secret-token")

      conn = get("/api/metrics") |> with_bearer("secret-token") |> MetricsController.show([])

      assert conn.status == 200
      body = JSON.decode!(conn.resp_body)
      assert Map.has_key?(body, "cpu")
      assert Map.has_key?(body, "memory")
      assert Map.has_key?(body, "ts")
    end

    test "200 history time series with ?since=" do
      Application.put_env(:sukhi_fedi, :metrics_token, "secret-token")
      insert_at(2_000, cpu_percent: 20.0)

      conn =
        get("/api/metrics?since=1000&until=3000")
        |> with_bearer("secret-token")
        |> MetricsController.show([])

      assert conn.status == 200
      body = JSON.decode!(conn.resp_body)
      assert body["count"] >= 1
      assert is_binary(hd(body["samples"])["sampled_at"])
    end

    test "400 on a non-numeric since" do
      Application.put_env(:sukhi_fedi, :metrics_token, "secret-token")

      conn =
        get("/api/metrics?since=abc")
        |> with_bearer("secret-token")
        |> MetricsController.show([])

      assert conn.status == 400
    end
  end
end
