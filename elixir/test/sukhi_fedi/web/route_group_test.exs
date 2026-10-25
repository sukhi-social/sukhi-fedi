# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.RouteGroupTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias SukhiFedi.Web.RouteGroup

  defp group(path), do: path |> then(&conn(:get, &1)) |> RouteGroup.of()

  test "names the kinds of request the load test tells apart" do
    assert group("/api/v1/timelines/public") == "timeline_public"
    assert group("/api/v1/timelines/home") == "timeline_home"
    assert group("/api/v1/timelines/tag/x") == "timeline_other"
    assert group("/api/v1/instance") == "api"
    assert group("/oauth/token") == "api"
    assert group("/login") == "auth"
    assert group("/users/alice/inbox") == "federation"
    assert group("/.well-known/webfinger") == "federation"
    assert group("/_app/immutable/a.js") == "static"
    assert group("/nowhere") == "other"
  end

  test "status keeps the busy codes exact and folds the rest into classes" do
    assert RouteGroup.status_label(429) == "429"
    assert RouteGroup.status_label(503) == "503"
    assert RouteGroup.status_label(200) == "2xx"
    assert RouteGroup.status_label(500) == "5xx"
    assert RouteGroup.status_label(nil) == "other"
  end

  test "the PromEx plugin builds its metric definitions" do
    assert %PromEx.MetricTypes.Event{} = SukhiFedi.PromEx.Load.event_metrics([])
  end
end
