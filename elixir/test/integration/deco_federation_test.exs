# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.DecoFederationTest do
  @moduledoc """
  natadeco の板(デコ)の Group actor — 実ルーターを通した HTTP の形。
  段階の最初(actor が引ける・webfinger で見つかる)だけを確かめる。
  Follow の受理・followers の中身はまだ先の段。

      podman compose -f docker-compose.test.yml up -d postgres nats nats-bootstrap
      MIX_ENV=test mix sukhi.migrate
      mix test --only integration test/integration/deco_federation_test.exs
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Plug.Conn
  import Plug.Test

  alias SukhiFedi.Addons.Deco
  alias SukhiFedi.LocalAccounts
  alias SukhiFedi.Web.Router

  @opts Router.init([])

  setup do
    prev = Application.get_env(:sukhi_fedi, :domain)
    Application.put_env(:sukhi_fedi, :domain, "localhost:4000")
    on_exit(fn -> Application.put_env(:sukhi_fedi, :domain, prev) end)

    n = System.unique_integer([:positive])
    {:ok, author} = LocalAccounts.create_admin("deco_fed_#{n}", "long-enough-pass")
    {:ok, deco} = Deco.create_deco(author, %{"slug" => "shiro#{n}", "name" => "しろい板"})
    %{deco: deco}
  end

  defp get_ap(path) do
    conn(:get, path)
    |> put_req_header("accept", "application/activity+json")
    |> Router.call(@opts)
  end

  test "GET /users/:slug-deco が Group actor JSON を返す", %{deco: deco} do
    conn = get_ap("/users/#{deco.slug}-deco")

    assert conn.status == 200
    assert conn |> Plug.Conn.get_resp_header("content-type") |> hd() =~ "application/activity+json"

    body = JSON.decode!(conn.resp_body)
    assert body["type"] == "Group"
    assert body["preferredUsername"] == "#{deco.slug}-deco"
    assert body["name"] == deco.name
    assert body["id"] == "https://localhost:4000/users/#{deco.slug}-deco"
    assert body["publicKey"]["publicKeyPem"] != ""
  end

  test "無い板の slug-deco は 404", do: assert(get_ap("/users/no-such-slug-deco").status == 404)

  test "webfinger が acct:slug-deco@domain を解決する", %{deco: deco} do
    conn = get_ap("/.well-known/webfinger?resource=acct:#{deco.slug}-deco@localhost:4000")

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    assert body["subject"] == "acct:#{deco.slug}-deco@localhost:4000"

    self_link = Enum.find(body["links"], &(&1["rel"] == "self"))
    assert self_link["href"] == "https://localhost:4000/users/#{deco.slug}-deco"
  end

  test "板の slug 自体(suffix 無し)は、板の actor としては解決しない", %{deco: deco} do
    # `hinata@domain` は個人アカウントの名前空間 ── デコの actor はいつも
    # `hinata-deco@domain` の方。無いアカウントとして 404 になる。
    conn = get_ap("/users/#{deco.slug}")
    assert conn.status == 404
  end
end
