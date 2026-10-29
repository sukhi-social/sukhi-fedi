# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.PullFederationHttpTest do
  @moduledoc """
  The two Pull Federation endpoints through the real router, with real HTTP
  signatures (the golden fixture key stands in for the peer `sukhi.test`).
  """

  use SukhiFedi.IntegrationCase, async: false
  @moduletag :integration

  import Plug.Conn
  import Plug.Test

  import Ecto.Query, only: [from: 2]

  alias SukhiFedi.Cache.Ets
  alias SukhiFedi.Fedi.{HttpSignature, JWK}
  alias SukhiFedi.FediGolden
  alias SukhiFedi.PullTables
  alias SukhiFedi.Schema.{Account, Follow}
  alias SukhiFedi.Web.Router

  @opts Router.init([])
  @domain "local.example"
  @peer "sukhi.test"

  setup do
    prev = Application.get_env(:sukhi_fedi, :domain)
    Application.put_env(:sukhi_fedi, :domain, @domain)
    Hammer.delete_buckets("pull_notify:#{@peer}")

    # The peer published where it takes notifications and serves its log.
    SukhiShared.PeerCapabilities.learn(Repo, %{
      "id" => "https://#{@peer}/users/x",
      "generator" => SukhiShared.Capability.generator(),
      "endpoints" => SukhiShared.Capability.endpoints(@peer)
    })

    # The peer's key document, so verification needs no network.
    doc = %{
      "id" => FediGolden.actor(),
      "type" => "Person",
      "publicKey" => %{
        "id" => FediGolden.key_id(),
        "owner" => FediGolden.actor(),
        "publicKeyPem" => FediGolden.public_key_pem()
      }
    }

    for uri <- [FediGolden.key_id(), FediGolden.actor()],
        do: Ets.put(:fedi_documents, uri, doc, 3600)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:sukhi_fedi, :domain, prev),
        else: Application.delete_env(:sukhi_fedi, :domain)

      Application.delete_env(:sukhi_shared, :pull_federation)
      Application.delete_env(:sukhi_fedi, :pull_federation)
    end)

    :ok
  end

  # Plug.Test refuses a `host` request header; the verifier substitutes our
  # public domain for it anyway, so the signed headers go on without it.
  defp with_headers(conn, headers) do
    headers
    |> Enum.reject(fn {k, _} -> String.downcase(k) == "host" end)
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  defp signed_post(path, body_map) do
    body = JSON.encode!(body_map)
    {:ok, key} = JWK.private_key(FediGolden.private_key_jwk())
    headers = HttpSignature.sign_post("https://#{@domain}#{path}", body, key, FediGolden.key_id())

    conn(:post, path, body)
    |> with_headers(headers)
    |> Router.call(@opts)
  end

  defp signed_get(path_and_query) do
    {:ok, key} = JWK.private_key(FediGolden.private_key_jwk())

    headers =
      HttpSignature.sign_get("https://#{@domain}#{path_and_query}", key, FediGolden.key_id())

    conn(:get, path_and_query)
    |> with_headers(headers)
    |> Router.call(@opts)
  end

  defp json(conn), do: JSON.decode!(conn.resp_body)

  defp reader_following_peer do
    reader = Repo.insert!(%Account{username: "reader", display_name: "r", summary: ""})

    shiro =
      Repo.insert!(%Account{
        username: "shiro",
        display_name: "s",
        summary: "",
        domain: @peer,
        actor_uri: FediGolden.actor(),
        inbox_url: FediGolden.actor() <> "/inbox"
      })

    Repo.insert!(%Follow{
      follower_uri: "https://#{@domain}/users/#{reader.username}",
      followee_id: shiro.id,
      state: "accepted"
    })

    shiro
  end

  describe "POST /pull/v1/notify" do
    test "an origin that never published its endpoints gets 404, so its sender pushes" do
      Repo.delete_all(from(p in "peer_capabilities", where: p.host == ^@peer))

      conn =
        signed_post("/pull/v1/notify", %{
          "type" => "PullNotification",
          "origin" => @peer,
          "heads" => %{"https://#{@peer}/users/x" => 1}
        })

      assert conn.status == 404
    end

    test "a signed notification from the origin is accepted and remembered" do
      reader_following_peer()

      conn =
        signed_post("/pull/v1/notify", %{
          "type" => "PullNotification",
          "origin" => @peer,
          "heads" => %{FediGolden.actor() => 4}
        })

      assert conn.status == 202

      assert [[actor, 4]] = PullTables.pending(@peer)

      assert actor == FediGolden.actor()
    end

    test "unsigned is 401 and remembers nothing" do
      reader_following_peer()

      conn =
        conn(
          :post,
          "/pull/v1/notify",
          JSON.encode!(%{
            "type" => "PullNotification",
            "origin" => @peer,
            "heads" => %{FediGolden.actor() => 4}
          })
        )
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 401
      assert Repo.all(from(p in "pull_pending", select: 1)) == []
    end

    test "the signer must be the origin it names" do
      reader_following_peer()

      conn =
        signed_post("/pull/v1/notify", %{
          "type" => "PullNotification",
          "origin" => "other.test",
          "heads" => %{"https://other.test/users/x" => 1}
        })

      assert conn.status == 403
    end

    test "a malformed notification is 400" do
      conn =
        signed_post("/pull/v1/notify", %{
          "type" => "PullNotification",
          "origin" => @peer,
          "heads" => %{}
        })

      assert conn.status == 400
    end

    test "a suspended instance is refused" do
      Repo.insert!(%SukhiFedi.Schema.InstanceBlock{domain: @peer, severity: "suspend"})

      conn =
        signed_post("/pull/v1/notify", %{
          "type" => "PullNotification",
          "origin" => @peer,
          "heads" => %{FediGolden.actor() => 1}
        })

      assert conn.status == 403
    end

    test "404 when we do not advertise the capability" do
      Application.put_env(:sukhi_shared, :pull_federation, false)

      conn =
        signed_post("/pull/v1/notify", %{
          "type" => "PullNotification",
          "origin" => @peer,
          "heads" => %{FediGolden.actor() => 1}
        })

      assert conn.status == 404
    end
  end

  describe "GET /pull/v1/stream" do
    setup do
      alice = Repo.insert!(%Account{username: "alice", display_name: "a", summary: ""})

      Repo.insert!(%Follow{
        follower_uri: FediGolden.actor(),
        followee_id: alice.id,
        state: "accepted"
      })

      PullTables.put_head(alice.id, 2)

      for seq <- 1..2 do
        Repo.insert_all("pull_log", [
          %{
            account_id: alice.id,
            seq: seq,
            activity_id: "act-#{seq}",
            body: %{"id" => "act-#{seq}", "type" => "Create"}
          }
        ])
      end

      {:ok,
       path: "/pull/v1/stream?" <> URI.encode_query([{"c[]", "0@https://#{@domain}/users/alice"}])}
    end

    test "a signed follower host gets the page", %{path: path} do
      conn = signed_get(path)
      assert conn.status == 200
      page = json(conn)
      assert Enum.map(page["items"], & &1["seq"]) == [1, 2]
      assert page["heads"] == %{"https://#{@domain}/users/alice" => 2}
    end

    test "unsigned is 401", %{path: path} do
      assert conn(:get, path) |> Router.call(@opts) |> Map.get(:status) == 401
    end

    test "a signed host that follows nobody of ours is 403" do
      path =
        "/pull/v1/stream?" <>
          URI.encode_query([{"c[]", "0@https://#{@domain}/users/nobody-here"}])

      assert signed_get(path).status == 403
    end

    test "when we are at capacity the answer is 429 with a retry hint", %{path: path} do
      Application.put_env(:sukhi_fedi, :pull_federation, tick_ms: nil, max_streams: 0)
      conn = signed_get(path)
      assert conn.status == 429
      assert [secs] = get_resp_header(conn, "retry-after")
      assert String.to_integer(secs) in 2..4
    end

    test "404 when we do not advertise the capability", %{path: path} do
      Application.put_env(:sukhi_shared, :pull_federation, false)
      assert signed_get(path).status == 404
    end
  end
end
