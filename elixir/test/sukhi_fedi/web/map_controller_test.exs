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

    assert %{"at" => at, "streams" => streams, "notes_5m" => notes} = body
    assert {:ok, _, _} = DateTime.from_iso8601(at)

    # stream ごとに nil（NATS 不在＝運転見合わせ）か {seq, held}。
    for key <- ~w(outbox outbox_dlq events) do
      case Map.fetch!(streams, key) do
        nil -> :ok
        %{"seq" => seq, "held" => held} -> assert is_integer(seq) and is_integer(held)
      end
    end

    assert %{"local" => local, "remote" => remote} = notes
    assert is_integer(local) and is_integer(remote)
  end

  test "counts recent notes split by locality" do
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

    body = show()

    assert body["notes_5m"]["local"] == body_before["notes_5m"]["local"] + 1
    assert body["notes_5m"]["remote"] == body_before["notes_5m"]["remote"] + 1
  end

  test "serves the second call within the window from cache" do
    body = show()
    # キャッシュ窓の内側なので、書き込んでも答えは変わらない。
    local = Repo.insert!(%Account{username: "map_cache", display_name: "c", summary: ""})
    Repo.insert!(%Note{account_id: local.id, content: "cached?", visibility: "public"})
    assert show() == body
  end
end
