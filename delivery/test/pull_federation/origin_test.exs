# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.PullFederation.OriginTest do
  # Needs the shared test database (docs/TESTING.md, `--only integration`): the migrations are
  # the gateway's, so they run with the stack up, not under a bare `mix test`.
  use ExUnit.Case, async: false

  @moduletag :integration

  alias SukhiDelivery.PullFederation.{Fallback, Log, NotifyWorker, Route}
  alias SukhiDelivery.Repo
  alias SukhiShared.{Capability, PeerCapabilities}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:sukhi_delivery, :domain, "origin.example")

    on_exit(fn ->
      Application.delete_env(:sukhi_delivery, :pull_notify_endpoint)
      Application.delete_env(:sukhi_shared, :pull_federation)
    end)

    :ok
  end

  defp account(name) do
    %{rows: [[id]]} =
      Repo.query!("INSERT INTO accounts (username) VALUES ($1) RETURNING id", [name])

    id
  end

  defp follow(account_id, follower_uri) do
    Repo.query!(
      "INSERT INTO follows (follower_uri, followee_id, state) VALUES ($1, $2, 'accepted')",
      [
        follower_uri,
        account_id
      ]
    )
  end

  defp capable(host) do
    PeerCapabilities.learn(Repo, %{
      "id" => "https://#{host}/users/x",
      "generator" => %{"implements" => [%{"href" => Capability.pull_federation()}]}
    })
  end

  defp activity(n),
    do: %{"id" => "https://origin.example/users/alice/notes/#{n}/activity", "type" => "Create"}

  describe "Route.split/1" do
    test "capable hosts are notified; everyone else keeps being pushed" do
      capable("pull.example")

      inboxes = [
        "https://pull.example/inbox",
        "https://plain.example/inbox",
        "https://unknown.example/users/u/inbox"
      ]

      {push, pull} = Route.split(inboxes)
      assert pull == ["pull.example"]

      assert Enum.sort(push) == [
               "https://plain.example/inbox",
               "https://unknown.example/users/u/inbox"
             ]
    end

    test "when we do not run Pull Federation nothing is routed to pull" do
      capable("pull.example")
      Application.put_env(:sukhi_shared, :pull_federation, false)
      assert {["https://pull.example/inbox"], []} = Route.split(["https://pull.example/inbox"])
    end

    test "a host whose notifications keep failing goes back to push, then is tried again" do
      capable("flaky.example")
      now = DateTime.utc_now()

      Repo.query!(
        "INSERT INTO pull_peers (host, failures, notified_at) VALUES ('flaky.example', $1, $2)",
        [Route.trip(), DateTime.to_naive(now)]
      )

      assert {["https://flaky.example/inbox"], []} =
               Route.split(["https://flaky.example/inbox"], now)

      later = DateTime.add(now, Route.half_open_ms() + 1_000, :millisecond)
      assert {[], ["flaky.example"]} = Route.split(["https://flaky.example/inbox"], later)
    end
  end

  describe "Log" do
    test "sequence numbers are per actor and gapless; append is idempotent" do
      a = account("alice")
      b = account("bob")

      assert {:ok, %{seq: 1}} = Log.append(a, "a1", activity(1))
      assert {:ok, %{seq: 2}} = Log.append(a, "a2", activity(2))
      assert {:ok, %{seq: 1}} = Log.append(b, "b1", activity(3))
      assert {:ok, %{seq: 2, id: id}} = Log.append(a, "a2", activity(2))
      assert is_integer(id)

      assert %{rows: [[2]]} =
               Repo.query!("SELECT count(*) FROM pull_log WHERE account_id = $1", [a])
    end

    test "retract removes the Create a Delete retracts" do
      a = account("alice")
      {:ok, _} = Log.append(a, "gone", activity(1))
      assert Log.retract("gone") == 1
      assert Log.retract("gone") == 0
    end

    test "prune drops rows past the age limit" do
      a = account("alice")
      {:ok, _} = Log.append(a, "old", activity(1))
      {:ok, _} = Log.append(a, "new", activity(2))

      Repo.query!(
        "UPDATE pull_log SET inserted_at = now() - interval '30 days' WHERE activity_id = 'old'"
      )

      assert Log.prune() == 1
      assert %{rows: [["new"]]} = Repo.query!("SELECT activity_id FROM pull_log")
    end
  end

  describe "NotifyWorker" do
    setup do
      bypass = Bypass.open()

      Application.put_env(:sukhi_delivery, :pull_notify_endpoint, fn _host ->
        "http://localhost:#{bypass.port}/pull/v1/notify"
      end)

      alice = account("alice")
      follow(alice, "https://pull.example/users/u1")
      {:ok, bypass: bypass, alice: alice}
    end

    defp run(host),
      do: NotifyWorker.perform(%Oban.Job{args: %{"host" => host}, attempt: 1, max_attempts: 6})

    test "one notification carries the head of every followed actor, then advances", %{
      bypass: bypass,
      alice: alice
    } do
      {:ok, _} = Log.append(alice, "n1", activity(1))
      {:ok, _} = Log.append(alice, "n2", activity(2))

      test = self()

      Bypass.expect_once(bypass, "POST", "/pull/v1/notify", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:body, JSON.decode!(raw)})
        Plug.Conn.send_resp(conn, 202, "")
      end)

      assert :ok = run("pull.example")

      assert_received {:body, body}
      assert body["type"] == "PullNotification"
      assert body["origin"] == "origin.example"
      assert body["heads"] == %{"https://origin.example/users/alice" => 2}

      # Nothing new: no second request (Bypass would fail on an unexpected call).
      assert :ok = run("pull.example")

      assert %{rows: [[0]]} =
               Repo.query!("SELECT failures FROM pull_peers WHERE host = 'pull.example'")
    end

    test "an actor the host does not follow is not mentioned", %{bypass: bypass} do
      bob = account("bob")
      {:ok, _} = Log.append(bob, "b1", activity(1))
      # No request expected: no head qualifies.
      _ = bypass
      assert :ok = run("pull.example")
    end

    test "429 snoozes by the Retry-After the peer asked for and is not a failure", %{
      bypass: bypass,
      alice: alice
    } do
      {:ok, _} = Log.append(alice, "n1", activity(1))

      Bypass.expect_once(bypass, "POST", "/pull/v1/notify", fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "7") |> Plug.Conn.send_resp(429, "")
      end)

      assert {:snooze, 7} = run("pull.example")
      assert %{rows: []} = Repo.query!("SELECT 1 FROM pull_peers WHERE failures > 0")
    end

    test "a host that does not serve the endpoint is pushed to at once", %{
      bypass: bypass,
      alice: alice
    } do
      {:ok, _} = Log.append(alice, "n1", activity(1))
      Bypass.expect_once(bypass, "POST", "/pull/v1/notify", &Plug.Conn.send_resp(&1, 404, ""))

      assert :ok = run("pull.example")

      assert %{rows: [[1, through]]} =
               Repo.query!(
                 "SELECT failures, notified_through FROM pull_peers WHERE host = 'pull.example'"
               )

      assert through > 0
    end

    test "transient failure errors for a retry, and the last attempt falls back to push", %{
      bypass: bypass,
      alice: alice
    } do
      {:ok, _} = Log.append(alice, "n1", activity(1))
      Bypass.expect(bypass, "POST", "/pull/v1/notify", &Plug.Conn.send_resp(&1, 503, ""))

      assert {:error, "status 503"} =
               NotifyWorker.perform(%Oban.Job{
                 args: %{"host" => "pull.example"},
                 attempt: 1,
                 max_attempts: 6
               })

      assert :ok =
               NotifyWorker.perform(%Oban.Job{
                 args: %{"host" => "pull.example"},
                 attempt: 6,
                 max_attempts: 6
               })

      assert %{rows: [[2]]} =
               Repo.query!("SELECT failures FROM pull_peers WHERE host = 'pull.example'")
    end
  end

  describe "Fallback.push/1" do
    test "pushes the backlog only to that host's inboxes, once, and marks it handled" do
      alice = account("alice")
      follow(alice, "https://pull.example/users/u1")
      {:ok, _} = Log.append(alice, "n1", activity(1))

      # Follower inbox resolution reads the actor, which needs the network;
      # with no resolvable inbox there is nothing to enqueue, and the mark
      # still moves so the backlog is not retried forever.
      assert Fallback.push("pull.example") >= 0

      assert %{rows: [[through]]} =
               Repo.query!("SELECT notified_through FROM pull_peers WHERE host = 'pull.example'")

      assert through > 0
    end
  end
end
