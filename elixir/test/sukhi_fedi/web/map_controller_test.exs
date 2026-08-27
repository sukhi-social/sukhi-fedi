# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MapControllerTest do
  # Repo に書き、controller の :persistent_term キャッシュを消すので not async。
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Plug.Test

  alias SukhiFedi.Schema.{Account, Note}
  alias SukhiFedi.Web.MapController

  setup do
    # 5 秒キャッシュを挟んでいるので、テスト同士が前の答えを見ないように毎回消す。
    :persistent_term.erase({MapController, :cache})
    :ok
  end

  defp show do
    conn = MapController.show(conn(:get, "/api/map"), [])
    assert conn.status == 200
    assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers
    JSON.decode!(conn.resp_body)
  end

  test "returns the counter shape without authentication" do
    body = show()

    assert %{
             "at" => at,
             "streams" => streams,
             "notes_24h" => notes,
             "deliveries_24h" => deliveries,
             "peers" => peers
           } = body

    assert is_list(peers)
    assert {:ok, _, _} = DateTime.from_iso8601(at)

    # `events` は DOMAIN_EVENTS の名残り。streaming は plain NATS で数を
    # 刻まないので、数えるものがそもそも無い＝いつも nil。
    assert Map.fetch!(streams, "events") == nil

    # 線ごとに nil（数字が取れない＝運転見合わせ）か {seq, held}。
    for key <- ~w(outbox outbox_dlq) do
      case Map.fetch!(streams, key) do
        nil -> :ok
        %{"seq" => seq, "held" => held} -> assert is_integer(seq) and is_integer(held)
      end
    end

    assert %{"local" => local, "remote" => remote} = notes
    assert is_integer(local) and is_integer(remote)
    assert is_integer(deliveries)
  end

  test "counts the day's notes split by locality, and delivered receipts" do
    body_before = show()
    :persistent_term.erase({MapController, :cache})

    local = Repo.insert!(%Account{username: "map_local", display_name: "l", summary: ""})

    remote =
      Repo.insert!(%Account{
        username: "map_remote",
        display_name: "r",
        summary: "",
        domain: "remote.example",
        actor_uri: "https://remote.example/users/map_remote",
        inbox_url: "https://remote.example/users/map_remote/inbox"
      })

    Repo.insert!(%Note{account_id: local.id, content: "hi", visibility: "public"})

    Repo.insert!(%Note{
      account_id: remote.id,
      content: "hello",
      visibility: "public",
      ap_id: "https://remote.example/notes/map-1",
      domain: "remote.example"
    })

    # delivery_receipts は delivery アプリの表なので schemaless で植える。
    now = NaiveDateTime.utc_now()

    Repo.insert_all("delivery_receipts", [
      %{
        activity_id: "https://sukhi.test/activities/map-1",
        inbox_url: "https://remote.example/inbox",
        status: "delivered",
        delivered_at: now,
        inserted_at: now
      },
      # failed は数えない
      %{
        activity_id: "https://sukhi.test/activities/map-2",
        inbox_url: "https://remote.example/inbox",
        status: "failed",
        delivered_at: now,
        inserted_at: now
      }
    ])

    body = show()

    assert body["notes_24h"]["local"] == body_before["notes_24h"]["local"] + 1
    assert body["notes_24h"]["remote"] == body_before["notes_24h"]["remote"] + 1
    assert body["deliveries_24h"] == body_before["deliveries_24h"] + 1
  end

  test "lists only allow-listed peers, with their day's note count" do
    body_before = show()
    refute Enum.any?(body_before["peers"], &(&1["domain"] == "starry.example"))
    :persistent_term.erase({MapController, :cache})

    remote =
      Repo.insert!(%Account{
        username: "map_star",
        display_name: "s",
        summary: "",
        domain: "starry.example",
        actor_uri: "https://starry.example/users/map_star",
        inbox_url: "https://starry.example/users/map_star/inbox"
      })

    Repo.insert!(%Note{
      account_id: remote.id,
      content: "twinkle",
      visibility: "public",
      ap_id: "https://starry.example/notes/map-star-1",
      domain: "starry.example"
    })

    # 星はリストに載せて、はじめて地図に出る
    local = Repo.insert!(%Account{username: "map_admin", display_name: "a", summary: ""})
    {:ok, _} = SukhiFedi.MapPeers.add("starry.example", local.id)

    body = show()
    star = Enum.find(body["peers"], &(&1["domain"] == "starry.example"))
    assert %{"notes_24h" => 1} = star
  end

  test "serves the second call within the window from cache" do
    body = show()
    # キャッシュ窓の内側なので、書き込んでも答えは変わらない。
    local = Repo.insert!(%Account{username: "map_cache", display_name: "c", summary: ""})
    Repo.insert!(%Note{account_id: local.id, content: "cached?", visibility: "public"})
    assert show() == body
  end
end
