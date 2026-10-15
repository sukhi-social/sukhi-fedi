# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonFollowsTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.Social, fun, args, _t), do: lookup(:fake_social, fun, args)
    def call(SukhiFedi.OAuth, fun, args, _t), do: lookup(:fake_oauth, fun, args)
    def call(_, _, _, _), do: {:error, :not_connected}

    defp lookup(env_key, fun, args) do
      table = Application.get_env(:sukhi_api, env_key, %{})

      case Map.get(table, {fun, args}, :not_configured) do
        :not_configured ->
          case Map.get(table, fun, :not_configured) do
            :not_configured -> {:error, :not_connected}
            v -> {:ok, v}
          end

        v ->
          {:ok, v}
      end
    end
  end

  setup do
    prev = %{
      rpc: Application.get_env(:sukhi_api, :gateway_rpc_impl),
      addons: Application.get_env(:sukhi_api, :enabled_addons),
      social: Application.get_env(:sukhi_api, :fake_social),
      oauth: Application.get_env(:sukhi_api, :fake_oauth)
    }

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_social, %{})

    on_exit(fn ->
      restore(:gateway_rpc_impl, prev.rpc)
      restore(:enabled_addons, prev.addons)
      restore(:fake_social, prev.social)
      restore(:fake_oauth, prev.oauth)
    end)

    :ok
  end

  defp viewer_fixture, do: %{id: 1, username: "me"}

  defp authed_post(path, scopes \\ ["write:follows"]) do
    Application.put_env(:sukhi_api, :fake_oauth, %{
      verify_bearer:
        {:ok, %{account: viewer_fixture(), app: %{id: 1, name: "x"}, scopes: scopes}}
    })

    %{
      method: "POST",
      path: path,
      headers: [{"authorization", "Bearer t"}, {"content-type", "application/json"}],
      body: ""
    }
  end

  describe "POST /api/v1/accounts/:id/follow" do
    test "returns Relationship with following=true (state accepted)" do
      Application.put_env(:sukhi_api, :fake_social, %{
        request_follow: {:ok, %{id: 99, follower_uri: "x", followee_id: 2, state: "pending"}},
        list_relationships: [
          %{id: 2, following: true, requested: false, followed_by: false, blocking: false}
        ]
      })

      {:ok, resp} = Router.handle(authed_post("/api/v1/accounts/2/follow"))
      assert resp.status == 200

      body = JSON.decode!(resp.body)
      assert body["id"] == "2"
      assert body["following"] == true
    end

    test "self-follow → 422" do
      Application.put_env(:sukhi_api, :fake_social, %{
        request_follow: {:error, :self_follow}
      })

      {:ok, resp} = Router.handle(authed_post("/api/v1/accounts/1/follow"))
      assert resp.status == 422
    end

    test "unknown target → 404" do
      Application.put_env(:sukhi_api, :fake_social, %{
        request_follow: {:error, :not_found}
      })

      {:ok, resp} = Router.handle(authed_post("/api/v1/accounts/9999/follow"))
      assert resp.status == 404
    end

    test "gateway drops out before the Relationship refetch → 503, not a 500" do
      # request_follow is answered; list_relationships is not configured, which
      # this fake reports as :not_connected.
      Application.put_env(:sukhi_api, :fake_social, %{request_follow: {:ok, %{id: 99}}})

      {:ok, resp} = Router.handle(authed_post("/api/v1/accounts/2/follow"))
      assert resp.status == 503
      assert JSON.decode!(resp.body) == %{"error" => "gateway_not_connected"}
    end

    test "missing token → 401" do
      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/api/v1/accounts/2/follow",
          headers: []
        })

      assert resp.status == 401
    end

    test "invalid id → 400" do
      Application.put_env(:sukhi_api, :fake_oauth, %{
        verify_bearer:
          {:ok, %{account: viewer_fixture(), app: %{id: 1, name: "x"}, scopes: ["write:follows"]}}
      })

      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/api/v1/accounts/notanint/follow",
          headers: [{"authorization", "Bearer t"}]
        })

      assert resp.status == 400
    end
  end

  describe "POST /api/v1/accounts/:id/unfollow" do
    test "returns Relationship with following=false on success" do
      Application.put_env(:sukhi_api, :fake_social, %{
        unfollow: {:ok, %{id: 99}},
        list_relationships: [
          %{id: 2, following: false, requested: false, followed_by: false}
        ]
      })

      {:ok, resp} = Router.handle(authed_post("/api/v1/accounts/2/unfollow"))
      assert resp.status == 200

      body = JSON.decode!(resp.body)
      assert body["following"] == false
    end

    test "no existing follow → still 200 (idempotent)" do
      Application.put_env(:sukhi_api, :fake_social, %{
        unfollow: {:error, :not_found},
        list_relationships: [%{id: 2, following: false}]
      })

      {:ok, resp} = Router.handle(authed_post("/api/v1/accounts/2/unfollow"))
      assert resp.status == 200
    end

    test "gateway unreachable → 503" do
      # Nothing configured: every call comes back :not_connected.
      {:ok, resp} = Router.handle(authed_post("/api/v1/accounts/2/unfollow"))
      assert resp.status == 503
      assert JSON.decode!(resp.body) == %{"error" => "gateway_not_connected"}
    end
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, value), do: Application.put_env(:sukhi_api, key, value)
end
