# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.SpaRoutesTest do
  # Not async: StaticFiles reads process-wide env vars.
  use ExUnit.Case, async: false

  alias SukhiFedi.Web.SpaRoutes

  @manifest ~S|{"routes": ["/", "/lists", "/lists/[id]", "/@[acct]", "/@[acct]/followers",
                          "/docs/[...rest]", "/(app)/inbox", "/blog/[[page]]/top", "/api"]}|

  defp page?(path), do: SpaRoutes.classify(String.split(path, "/", trim: true)) == :page

  setup do
    root = Path.join(System.tmp_dir!(), "spa_routes_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "override"))
    File.mkdir_p!(Path.join(root, "baked"))
    System.put_env("STATIC_OVERRIDE_DIR", Path.join(root, "override"))
    System.put_env("STATIC_BAKED_DIR", Path.join(root, "baked"))

    on_exit(fn ->
      System.delete_env("STATIC_OVERRIDE_DIR")
      System.delete_env("STATIC_BAKED_DIR")
      File.rm_rf!(root)
    end)

    %{override: Path.join(root, "override"), baked: Path.join(root, "baked")}
  end

  test "no manifest is reported as such, not as \"not a page\"" do
    assert SpaRoutes.classify(["lists"]) == :no_manifest
    refute page?("/lists")
  end

  describe "with a manifest" do
    setup %{baked: baked} do
      File.write!(Path.join(baked, "routes.json"), @manifest)
      :ok
    end

    test "literal and parameter pages" do
      assert page?("/")
      assert page?("/lists")
      assert page?("/lists/42")
      refute page?("/lists/42/extra")
      refute page?("/nope")
    end

    test "a parameter inside a segment keeps its literal part" do
      assert page?("/@alice")
      assert page?("/@alice/followers")
      refute page?("/alice")
      refute page?("/@")
    end

    test "rest, optional and group segments" do
      assert page?("/docs/a/b/c")
      assert page?("/docs")
      assert page?("/inbox")
      assert page?("/blog/top")
      assert page?("/blog/3/top")
      refute page?("/blog/3/4/top")
    end

    test "page_request? is true only for a browser GET of a page" do
      html = fn method, path ->
        Plug.Test.conn(method, path) |> Plug.Conn.put_req_header("accept", "text/html,*/*;q=0.8")
      end

      assert SpaRoutes.page_request?(html.(:get, "/"))
      assert SpaRoutes.page_request?(html.(:get, "/lists/42"))
      assert SpaRoutes.page_request?(html.(:head, "/lists"))

      refute SpaRoutes.page_request?(html.(:post, "/lists"))
      refute SpaRoutes.page_request?(html.(:get, "/nowhere"))
      refute SpaRoutes.page_request?(html.(:get, "/lists/42/__data.json"))
      # an ActivityPub fetch of a page that is also an actor URL
      refute SpaRoutes.page_request?(
               Plug.Test.conn(:get, "/@alice")
               |> Plug.Conn.put_req_header("accept", "application/activity+json")
             )

      refute SpaRoutes.page_request?(Plug.Test.conn(:get, "/lists"))
    end

    test "over the limit, the shell still passes and the API does not" do
      alias SukhiFedi.Web.RateLimitPlug
      {:ok, _} = Application.ensure_all_started(:hammer)

      o =
        RateLimitPlug.init(
          bucket: "spa#{System.unique_integer([:positive])}",
          limit: 1,
          scale_ms: 60_000,
          skip_if: &SpaRoutes.page_request?/1
        )

      api = fn -> RateLimitPlug.call(Plug.Test.conn(:get, "/api/v1/instance"), o) end
      refute api.().halted
      assert api.().status == 429

      shell =
        Plug.Test.conn(:get, "/lists/7")
        |> Plug.Conn.put_req_header("accept", "text/html")

      for _ <- 1..20, do: refute(RateLimitPlug.call(shell, o).halted)
    end

    test "a pushed manifest replaces the baked one without a restart", %{override: override} do
      refute page?("/fresh")
      File.write!(Path.join(override, "routes.json"), ~s({"routes": ["/fresh"]}))
      assert page?("/fresh")
    end
  end

  test "a malformed manifest claims nothing", %{baked: baked} do
    File.write!(Path.join(baked, "routes.json"), "{not json")
    refute page?("/")
    assert SpaRoutes.classify([]) == :not_page
  end
end
