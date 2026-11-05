# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.IntakePlugTest do
  # Not async: the intake state is one switch for the whole BEAM.
  use ExUnit.Case, async: false

  import Plug.Test

  alias SukhiFedi.Web.{IntakePlug, Router}
  alias SukhiShared.Intake

  setup do
    {:ok, _} = Application.ensure_all_started(:hammer)
    dir = Path.join(System.tmp_dir!(), "intake-plug-#{System.unique_integer([:positive])}")
    Application.put_env(:sukhi_shared, :intake_file, Path.join(dir, "intake.json"))
    Intake.open()

    on_exit(fn ->
      Intake.open()
      Application.delete_env(:sukhi_shared, :intake_file)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp call(method, path), do: IntakePlug.call(conn(method, path), IntakePlug.init([]))

  describe "open" do
    test "lets every method through" do
      for method <- [:get, :head, :options, :post, :put, :patch, :delete] do
        refute call(method, "/api/v1/statuses").halted, "#{method} was stopped while open"
      end
    end
  end

  describe "closed" do
    setup do
      Intake.close(reason: "backup", retry_after_s: 120)
      :ok
    end

    test "reads and preflights pass: a read-only server, not a dead one" do
      for method <- [:get, :head, :options] do
        refute call(method, "/api/v1/timelines/home").halted
      end
    end

    test "every other method is a 503 with Retry-After, before any body is read" do
      for method <- [:post, :put, :patch, :delete] do
        conn = call(method, "/api/v1/statuses")

        assert conn.halted
        assert conn.status == 503
        assert Plug.Conn.get_resp_header(conn, "retry-after") == ["120"]
        assert Plug.Conn.get_resp_header(conn, "x-sukhi-intake") == ["closed"]
        assert %{"error" => "maintenance", "retry_after" => 120} = JSON.decode!(conn.resp_body)
      end
    end

    test "the federation inboxes are refused with a 5xx, so the sender keeps the activity" do
      for path <- ["/inbox", "/users/alice/inbox"] do
        conn = call(:post, path)
        assert conn.halted
        assert conn.status == 503
      end
    end

    test "the rule is the method, not a list of paths: a route nobody listed is gated too" do
      assert call(:post, "/api/v1/some/route/added/next/year").status == 503
      assert call(:post, "/login").status == 503
    end

    test "opening again lets writes through" do
      Intake.open()
      refute call(:post, "/api/v1/statuses").halted
    end
  end

  describe "in the router" do
    test "while closed a POST to the inbox never reaches the inbox" do
      Intake.close()
      conn = Router.call(conn(:post, "/inbox", "{}"), Router.init([]))
      assert conn.status == 503
      assert Plug.Conn.get_resp_header(conn, "x-sukhi-intake") == ["closed"]
    end

    test "/.sukhi/intake.json says the door is open" do
      conn = Router.call(conn(:get, "/.sukhi/intake.json"), Router.init([]))

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert %{"state" => "open"} = JSON.decode!(conn.resp_body)
    end

    test "/.sukhi/intake.json still answers while closed, with no path and no backup in it" do
      Intake.close(reason: "update", retry_after_s: 60)
      Intake.note(:backup, %{dir: "/secret/place", at: DateTime.utc_now()})

      conn = Router.call(conn(:get, "/.sukhi/intake.json"), Router.init([]))

      assert conn.status == 200
      body = JSON.decode!(conn.resp_body)
      assert %{"state" => "closed", "reason" => "update", "retry_after_s" => 60} = body
      refute conn.resp_body =~ "secret"
    end
  end
end
