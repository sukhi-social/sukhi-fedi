# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.SukhiBotsTest do
  @moduledoc """
  手だけの垢の口。gateway は差し替えて、見るのは「どの呼び出しに
  落ちるか」「admin でないと入れないか」「返る形」だけ。
  """

  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.LocalAccounts, fun, args, _t) do
      table = Application.get_env(:sukhi_api, :fake_bots, %{})

      case Map.get(table, {fun, args}, :not_configured) do
        :not_configured -> {:error, :not_connected}
        v -> {:ok, v}
      end
    end

    def call(SukhiFedi.OAuth, fun, _args, _t) do
      table = Application.get_env(:sukhi_api, :fake_oauth, %{})

      case Map.get(table, fun, :not_configured) do
        :not_configured -> {:error, :not_connected}
        v -> {:ok, v}
      end
    end

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  @viewer %{id: 7, username: "alice", display_name: "A", summary: "", is_admin: false}
  @admin %{id: 9, username: "hinata", display_name: "ひなた", summary: "", is_admin: true}
  @bot %{id: 21, username: "shiro", display_name: "シロ", summary: "", is_bot: true}

  setup do
    prev = %{
      rpc: Application.get_env(:sukhi_api, :gateway_rpc_impl),
      addons: Application.get_env(:sukhi_api, :enabled_addons),
      bots: Application.get_env(:sukhi_api, :fake_bots),
      oauth: Application.get_env(:sukhi_api, :fake_oauth)
    }

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_bots, %{})
    signed_in_as(@viewer)

    on_exit(fn ->
      restore(:gateway_rpc_impl, prev.rpc)
      restore(:enabled_addons, prev.addons)
      restore(:fake_bots, prev.bots)
      restore(:fake_oauth, prev.oauth)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, v), do: Application.put_env(:sukhi_api, key, v)

  # web も natadeco も token は `read write …` ── umbrella が write:accounts を包む。
  defp signed_in_as(account) do
    Application.put_env(:sukhi_api, :fake_oauth, %{
      verify_bearer:
        {:ok, %{account: account, app: %{id: 1, name: "x"}, scopes: ["read", "write"]}}
    })
  end

  defp stub(pairs), do: Application.put_env(:sukhi_api, :fake_bots, Map.new(pairs))

  defp post(path, body) do
    Router.handle(%{
      method: "POST",
      path: path,
      headers: [{"authorization", "Bearer t"}, {"content-type", "application/json"}],
      body: JSON.encode!(body)
    })
  end

  test "admin が作ると、垢と鍵が一度だけ返る(余分な欄は gateway に渡らない)" do
    signed_in_as(@admin)

    stub([
      {{:create_bot, [9, %{"username" => "shiro", "display_name" => "シロ"}]},
       {:ok, %{account: @bot, token: "k3y"}}}
    ])

    {:ok, resp} =
      post("/api/v1/sukhi/bots", %{username: "shiro", display_name: "シロ", is_admin: true})

    assert resp.status == 201

    assert %{"token" => "k3y", "account" => %{"username" => "shiro", "bot" => true}} =
             JSON.decode!(resp.body)
  end

  test "admin でなければ 403(トークンは有効でも)" do
    {:ok, resp} = post("/api/v1/sukhi/bots", %{username: "shiro"})
    assert resp.status == 403
    assert %{"error" => "admin_required"} = JSON.decode!(resp.body)
  end

  test "トークンが無ければ 401" do
    {:ok, resp} =
      Router.handle(%{
        method: "POST",
        path: "/api/v1/sukhi/bots",
        headers: [{"content-type", "application/json"}],
        body: JSON.encode!(%{username: "shiro"})
      })

    assert resp.status == 401
  end

  test "同じ名前は 422 で欄の名前が返る" do
    signed_in_as(@admin)

    stub([
      {{:create_bot, [9, %{"username" => "shiro"}]},
       {:error, {:validation, %{username: ["taken"]}}}}
    ])

    {:ok, resp} = post("/api/v1/sukhi/bots", %{username: "shiro"})
    assert resp.status == 422
    assert %{"detail" => %{"username" => _}} = JSON.decode!(resp.body)
  end

  test "鍵の取り替えは admin.id と bot の id で gateway へ" do
    signed_in_as(@admin)
    stub([{{:rotate_bot_token, [9, 21]}, {:ok, %{account: @bot, token: "n3w"}}}])

    {:ok, resp} = post("/api/v1/sukhi/bots/21/token", %{})
    assert resp.status == 200
    assert %{"token" => "n3w"} = JSON.decode!(resp.body)
  end

  test "居ない bot は 404、数字でない id は 400" do
    signed_in_as(@admin)
    stub([{{:rotate_bot_token, [9, 404]}, {:error, :not_found}}])

    {:ok, resp} = post("/api/v1/sukhi/bots/404/token", %{})
    assert resp.status == 404

    {:ok, resp} = post("/api/v1/sukhi/bots/abc/token", %{})
    assert resp.status == 400
  end

  test "本人が名前と期限つきで鍵を足す(admin でなくてよい・余分な欄は渡らない)" do
    stub([
      {{:issue_personal_token, [7, %{"name" => "ci", "expires_in_days" => 30}]},
       {:ok, %{name: "ci", token: "k3y", expires_in_days: 30}}}
    ])

    {:ok, resp} =
      post("/api/v1/sukhi/tokens", %{name: "ci", expires_in_days: 30, is_admin: true})

    assert resp.status == 201

    assert %{"token" => "k3y", "name" => "ci", "expires_in_days" => 30} =
             JSON.decode!(resp.body)
  end

  test "名前や期限が悪いと 422 (gateway の検証がそのまま返る)" do
    stub([
      {{:issue_personal_token, [7, %{"name" => "ci", "expires_in_days" => 9999}]},
       {:error, {:validation, %{expires_in_days: ["invalid"]}}}}
    ])

    {:ok, resp} = post("/api/v1/sukhi/tokens", %{name: "ci", expires_in_days: 9999})
    assert resp.status == 422
  end
end
