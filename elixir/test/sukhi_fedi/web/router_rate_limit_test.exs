# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.RouterRateLimitTest do
  # Not async: StaticFiles reads process-wide env vars.
  use ExUnit.Case, async: false
  import Plug.Test

  alias SukhiFedi.Web.Router

  # The point of letting the shell through is the whole chain: an IP that
  # has used up the global limit still gets the page (which can then show
  # the busy notice), while its API calls get 429 with retry_after.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:hammer)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "router_rl_test_#{System.unique_integer([:positive])}")
    baked = Path.join(root, "baked")
    File.mkdir_p!(Path.join(root, "override"))
    File.mkdir_p!(baked)
    File.write!(Path.join(baked, "index.html"), "<!doctype html><title>shell</title>")
    File.write!(Path.join(baked, "routes.json"), ~s({"routes": ["/", "/lists/[id]"]}))
    System.put_env("STATIC_OVERRIDE_DIR", Path.join(root, "override"))
    System.put_env("STATIC_BAKED_DIR", baked)

    on_exit(fn ->
      System.delete_env("STATIC_OVERRIDE_DIR")
      System.delete_env("STATIC_BAKED_DIR")
      File.rm_rf!(root)
    end)
  end

  defp get(path, ip, accept) do
    conn(:get, path)
    |> Plug.Conn.put_req_header("cf-connecting-ip", ip)
    |> Plug.Conn.put_req_header("accept", accept)
    |> Router.call(Router.init([]))
  end

  test "an IP over the global limit still gets the SPA shell, and a 429 with retry_after for the API" do
    ip = "203.0.113.#{System.unique_integer([:positive])}"

    # Use the window up on a path the router answers without a DB or a node.
    for _ <- 1..500, do: get("/nowhere", ip, "application/json")

    limited = get("/nowhere", ip, "application/json")
    assert limited.status == 429
    assert %{"error" => "rate_limited", "retry_after" => n} = JSON.decode!(limited.resp_body)
    assert is_integer(n) and n > 0

    shell = get("/lists/7", ip, "text/html,application/xhtml+xml")
    assert shell.status == 200, "a page must load while limited"
    assert shell.resp_body =~ "<title>shell</title>"

    # A fetch that merely asks for JSON at a page URL is still counted.
    assert get("/lists/7", ip, "application/json").status == 429
  end
end
