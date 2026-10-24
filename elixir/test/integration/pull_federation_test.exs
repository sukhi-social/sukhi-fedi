# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.PullFederationTest do
  @moduledoc """
  The gateway half of Pull Federation against a real database: accepting a
  notification, serving a page of the log, and pulling from a (Bypass) origin
  through `AP.Ingest`.
  """

  use SukhiFedi.IntegrationCase, async: false
  @moduletag :integration

  alias SukhiFedi.PullFederation.{Notify, Pull, Puller, Serve}
  alias SukhiFedi.Schema.{Account, Follow, Note}

  @peer "peer.example"

  setup do
    Application.put_env(:sukhi_shared, :disable_url_guard, true)
    # The rate floor is per origin and lives in Hammer's ETS, shared across tests.
    Hammer.delete_buckets("pull_notify:#{@peer}")

    on_exit(fn ->
      Application.delete_env(:sukhi_shared, :disable_url_guard)
      Application.delete_env(:sukhi_fedi, :pull_federation)
    end)

    :ok
  end

  defp local!(name), do: Repo.insert!(%Account{username: name, display_name: name, summary: ""})

  defp remote!(name, domain) do
    Repo.insert!(%Account{
      username: name,
      display_name: name,
      summary: "",
      domain: domain,
      actor_uri: "https://#{domain}/users/#{name}",
      inbox_url: "https://#{domain}/users/#{name}/inbox"
    })
  end

  defp follow!(follower_uri, followee, state \\ "accepted"),
    do: Repo.insert!(%Follow{follower_uri: follower_uri, followee_id: followee.id, state: state})

  defp log!(account, seq, body \\ %{"type" => "Create"}) do
    Repo.query!(
      "INSERT INTO pull_heads (account_id, seq) VALUES ($1, $2) ON CONFLICT (account_id) DO UPDATE SET seq = GREATEST(pull_heads.seq, $2)",
      [account.id, seq]
    )

    Repo.query!(
      "INSERT INTO pull_log (account_id, seq, activity_id, body) VALUES ($1, $2, $3, $4)",
      [
        account.id,
        seq,
        "act-#{account.id}-#{seq}",
        body
      ]
    )
  end

  defp pending(host),
    do:
      Repo.query!("SELECT actor_uri, head FROM pull_pending WHERE host = $1 ORDER BY 1", [host]).rows

  defp cursor(uri),
    do: Repo.query!("SELECT seq FROM pull_cursors WHERE actor_uri = $1", [uri]).rows

  describe "Notify.accept/2" do
    test "remembers heads for actors a local user follows, ignores the rest" do
      mine = local!("reader")
      bob = remote!("bob", @peer)
      _stranger = remote!("stranger", @peer)

      follow!(
        "https://#{Application.get_env(:sukhi_fedi, :domain) || "localhost"}/users/reader",
        bob
      )

      _ = mine

      heads = [
        {bob.actor_uri, 5},
        {"https://#{@peer}/users/stranger", 9},
        {"https://#{@peer}/users/nobody", 2}
      ]

      assert {:ok, 1} = Notify.accept(@peer, heads)
      assert pending(@peer) == [[bob.actor_uri, 5]]
    end

    test "a newer head replaces an older one; an older one never lowers it" do
      reader = local!("reader")
      bob = remote!("bob", @peer)
      follow!("https://local.example/users/#{reader.username}", bob)

      assert {:ok, 1} = Notify.accept(@peer, [{bob.actor_uri, 5}])
      assert {:ok, 1} = Notify.accept(@peer, [{bob.actor_uri, 3}])
      assert pending(@peer) == [[bob.actor_uri, 5]]
      assert {:ok, 1} = Notify.accept(@peer, [{bob.actor_uri, 8}])
      assert pending(@peer) == [[bob.actor_uri, 8]]
    end

    test "a head we have already applied is not wanted" do
      reader = local!("reader")
      bob = remote!("bob", @peer)
      follow!("https://local.example/users/#{reader.username}", bob)

      Repo.query!(
        "INSERT INTO pull_cursors (actor_uri, host, seq, updated_at) VALUES ($1, $2, 7, now())",
        [bob.actor_uri, @peer]
      )

      assert {:dropped, :nothing_wanted} = Notify.accept(@peer, [{bob.actor_uri, 7}])
      assert {:ok, 1} = Notify.accept(@peer, [{bob.actor_uri, 8}])
    end

    test "a pending follow does not count" do
      reader = local!("reader")
      bob = remote!("bob", @peer)
      follow!("https://local.example/users/#{reader.username}", bob, "pending")
      assert {:dropped, :nothing_wanted} = Notify.accept(@peer, [{bob.actor_uri, 1}])
    end

    test "an origin that notifies faster than the floor is dropped" do
      reader = local!("reader")
      bob = remote!("bob", "flood.example")
      follow!("https://local.example/users/#{reader.username}", bob)

      results = for n <- 1..8, do: Notify.accept("flood.example", [{bob.actor_uri, n}])
      assert {:dropped, :rate_floor} in results
      assert {:ok, 1} = hd(results)
    end
  end

  describe "Serve.page/3" do
    setup do
      alice = local!("alice")
      follow!("https://#{@peer}/users/f1", alice)
      for seq <- 1..5, do: log!(alice, seq, %{"id" => "a#{seq}", "type" => "Create"})
      {:ok, alice: alice, uri: "https://local.example/users/alice"}
    end

    test "returns the rows after the cursor, in order, with the head", %{uri: uri} do
      assert {:ok, page} = Serve.page(@peer, [{uri, 2}], "local.example")
      assert page["type"] == "PullPage"
      assert Enum.map(page["items"], & &1["seq"]) == [3, 4, 5]
      assert hd(page["items"])["actor"] == uri
      assert hd(page["items"])["activity"]["id"] == "a3"
      assert page["heads"] == %{uri => 5}
      assert page["more"] == false
      assert page["resync"] == []
    end

    test "a host that follows nobody of ours gets nothing", %{uri: uri} do
      assert {:error, :denied} = Serve.page("other.example", [{uri, 0}], "local.example")
    end

    test "an actor that is not ours, or does not exist, is not served", %{uri: uri} do
      assert {:error, :denied} =
               Serve.page(
                 @peer,
                 [
                   {"https://elsewhere.example/users/alice", 0},
                   {"https://local.example/users/ghost", 0}
                 ],
                 "local.example"
               )

      assert {:ok, page} =
               Serve.page(
                 @peer,
                 [{uri, 0}, {"https://local.example/users/ghost", 0}],
                 "local.example"
               )

      assert Map.keys(page["heads"]) == [uri]
    end

    test "a first-time puller (cursor 0) gets the newest window, not the whole history", %{
      alice: alice,
      uri: uri
    } do
      for seq <- 6..40, do: log!(alice, seq)
      assert {:ok, page} = Serve.page(@peer, [{uri, 0}], "local.example")
      assert length(page["items"]) == 20
      assert hd(page["items"])["seq"] == 21
    end

    test "pages are bounded and say there is more", %{alice: alice, uri: uri} do
      for seq <- 6..150, do: log!(alice, seq)
      assert {:ok, page} = Serve.page(@peer, [{uri, 1}], "local.example")
      assert length(page["items"]) == Serve.page_items()
      assert page["more"] == true
    end

    test "a cursor behind the prune line is told to resync", %{alice: alice, uri: uri} do
      Repo.query!("DELETE FROM pull_log WHERE account_id = $1 AND seq <= 3", [alice.id])
      Repo.query!("UPDATE pull_heads SET pruned_through = 3 WHERE account_id = $1", [alice.id])

      assert {:ok, page} = Serve.page(@peer, [{uri, 1}], "local.example")
      assert page["resync"] == [uri]
      assert Enum.map(page["items"], & &1["seq"]) == [4, 5]
    end

    test "a gap from a retracted activity is not a resync", %{alice: alice, uri: uri} do
      Repo.query!("DELETE FROM pull_log WHERE account_id = $1 AND seq = 3", [alice.id])
      assert {:ok, page} = Serve.page(@peer, [{uri, 1}], "local.example")
      assert page["resync"] == []
      assert Enum.map(page["items"], & &1["seq"]) == [2, 4, 5]
    end
  end

  describe "Pull.run/1 against an origin" do
    setup %{mock_remote: bypass} do
      Application.put_env(:sukhi_fedi, :pull_federation,
        tick_ms: nil,
        stream_base: fn _host -> "http://localhost:#{bypass.port}/pull/v1/stream" end
      )

      reader = local!("reader")
      bob = remote!("bob", @peer)
      follow!("https://local.example/users/#{reader.username}", bob)

      Repo.query!(
        "INSERT INTO pull_pending (host, actor_uri, head, received_at) VALUES ($1, $2, 2, now())",
        [@peer, bob.actor_uri]
      )

      {:ok, bob: bob}
    end

    defp create_note(bob, n) do
      %{
        "id" => "https://#{@peer}/users/bob/notes/#{n}/activity",
        "type" => "Create",
        "actor" => bob.actor_uri,
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => %{
          "id" => "https://#{@peer}/users/bob/notes/#{n}",
          "type" => "Note",
          "attributedTo" => bob.actor_uri,
          "content" => "pulled #{n}",
          "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }
    end

    test "applies the page through Ingest, advances the cursor, clears the pending row", %{
      mock_remote: bypass,
      bob: bob
    } do
      test = self()

      Bypass.expect_once(bypass, "GET", "/pull/v1/stream", fn conn ->
        send(test, {:query, conn.query_string})

        page = %{
          "type" => "PullPage",
          "items" => [
            %{"actor" => bob.actor_uri, "seq" => 1, "activity" => create_note(bob, 1)},
            %{"actor" => bob.actor_uri, "seq" => 2, "activity" => create_note(bob, 2)}
          ],
          "heads" => %{bob.actor_uri => 2},
          "more" => false,
          "resync" => []
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(page))
      end)

      assert {:ok, %{applied: 2, more: false}} = Pull.run(@peer)

      assert_received {:query, qs}
      assert URI.decode_query(qs)["c[]"] == "0@#{bob.actor_uri}"

      assert Repo.get_by(Note, ap_id: "https://#{@peer}/users/bob/notes/1")
      assert Repo.get_by(Note, ap_id: "https://#{@peer}/users/bob/notes/2")
      assert cursor(bob.actor_uri) == [[2]]
      assert pending(@peer) == []
    end

    test "an activity claiming a different actor is refused, and the cursor still moves", %{
      mock_remote: bypass,
      bob: bob
    } do
      forged = create_note(bob, 1) |> Map.put("actor", "https://#{@peer}/users/someone-else")

      Bypass.expect_once(bypass, "GET", "/pull/v1/stream", fn conn ->
        page = %{
          "type" => "PullPage",
          "items" => [%{"actor" => bob.actor_uri, "seq" => 1, "activity" => forged}],
          "heads" => %{bob.actor_uri => 2},
          "more" => false
        }

        Plug.Conn.send_resp(conn, 200, JSON.encode!(page))
      end)

      assert {:ok, _} = Pull.run(@peer)
      refute Repo.get_by(Note, ap_id: "https://#{@peer}/users/bob/notes/1")
      assert cursor(bob.actor_uri) == [[2]]
    end

    test "an item for an actor we did not ask about is ignored", %{mock_remote: bypass, bob: bob} do
      Bypass.expect_once(bypass, "GET", "/pull/v1/stream", fn conn ->
        other = %{bob | actor_uri: "https://#{@peer}/users/other"}

        page = %{
          "type" => "PullPage",
          "items" => [
            %{"actor" => other.actor_uri, "seq" => 1, "activity" => create_note(other, 9)}
          ],
          "heads" => %{},
          "more" => true
        }

        Plug.Conn.send_resp(conn, 200, JSON.encode!(page))
      end)

      assert {:ok, %{more: true}} = Pull.run(@peer)
      refute Repo.get_by(Note, ap_id: "https://#{@peer}/users/bob/notes/9")
      assert pending(@peer) != []
    end

    test "429 becomes a decline that honours Retry-After", %{mock_remote: bypass} do
      Bypass.expect_once(bypass, "GET", "/pull/v1/stream", fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "9") |> Plug.Conn.send_resp(429, "{}")
      end)

      assert {:declined, 9} = Pull.run(@peer)
      assert pending(@peer) != []
    end

    test "a server error is a failure, and the scheduler backs the host off", %{
      mock_remote: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/pull/v1/stream", &Plug.Conn.send_resp(&1, 500, ""))
      assert {:error, {:http_status, 500}} = outcome = Pull.run(@peer)

      Puller.record(@peer, outcome)

      assert [[1, ms]] =
               Repo.query!(
                 "SELECT failures, (extract(epoch from next_pull_at - now()) * 1000)::int FROM pull_hosts WHERE host = $1",
                 [@peer]
               ).rows

      assert ms > 0

      Puller.record(@peer, {:ok, %{applied: 0, more: false}})
      assert [[0]] = Repo.query!("SELECT failures FROM pull_hosts WHERE host = $1", [@peer]).rows
    end

    test "a malformed page is a failure, not a crash", %{mock_remote: bypass} do
      Bypass.expect_once(
        bypass,
        "GET",
        "/pull/v1/stream",
        &Plug.Conn.send_resp(&1, 200, "not json")
      )

      assert {:error, :bad_page} = Pull.run(@peer)
    end

    test "nothing pending is idle and makes no request" do
      Repo.query!("DELETE FROM pull_pending")
      assert :idle = Pull.run(@peer)
    end
  end
end
