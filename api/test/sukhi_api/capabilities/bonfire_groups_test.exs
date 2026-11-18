# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.BonfireGroupsTest do
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

  describe "POST /api/v1-bonfire/groups/:id/join" do
    test "answers the Relationship: requested, and not yet a member" do
      Application.put_env(:sukhi_api, :fake_social, %{
        join_group: {:ok, %{id: 7, state: "pending"}},
        list_relationships: [
          %{id: 2, following: false, requested: true, group: %{member: false, role: nil}}
        ]
      })

      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/2/join"))
      assert resp.status == 200

      body = JSON.decode!(resp.body)
      assert body["id"] == "2"
      assert body["requested"] == true
      assert body["group"] == %{"member" => false, "role" => nil}
    end

    test "an accepted membership shows as member" do
      Application.put_env(:sukhi_api, :fake_social, %{
        join_group: {:ok, %{id: 7, state: "accepted"}},
        list_relationships: [
          %{id: 2, following: true, requested: false, group: %{member: true, role: "member"}}
        ]
      })

      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/2/join"))

      assert JSON.decode!(resp.body)["group"] == %{"member" => true, "role" => "member"}
    end

    test "a local account is not a group to join → 422" do
      Application.put_env(:sukhi_api, :fake_social, %{join_group: {:error, :not_remote}})

      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/2/join"))

      assert resp.status == 422
      assert JSON.decode!(resp.body) == %{"error" => "not a remote group"}
    end

    test "unknown group → 404" do
      Application.put_env(:sukhi_api, :fake_social, %{join_group: {:error, :not_found}})

      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/9999/join"))

      assert resp.status == 404
      assert JSON.decode!(resp.body) == %{"error" => "group_not_found"}
    end

    test "invalid id → 400" do
      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/notanint/join"))
      assert resp.status == 400
    end

    test "a read-only token can't join" do
      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/2/join", ["read"]))
      assert resp.status in [401, 403]
    end

    test "missing token → 401" do
      {:ok, resp} =
        Router.handle(%{method: "POST", path: "/api/v1-bonfire/groups/2/join", headers: []})

      assert resp.status == 401
    end

    test "gateway drops out before the Relationship refetch → 503, not a 500" do
      Application.put_env(:sukhi_api, :fake_social, %{join_group: {:ok, %{id: 7}}})

      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/2/join"))

      assert resp.status == 503
      assert JSON.decode!(resp.body) == %{"error" => "gateway_not_connected"}
    end
  end

  describe "POST /api/v1-bonfire/groups/:id/leave" do
    test "answers the Relationship without a group key once the membership is gone" do
      Application.put_env(:sukhi_api, :fake_social, %{
        leave_group: {:ok, %{id: 7}},
        list_relationships: [%{id: 2, following: true, requested: false, group: nil}]
      })

      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/2/leave"))
      assert resp.status == 200

      body = JSON.decode!(resp.body)
      assert body["following"] == true
      refute Map.has_key?(body, "group")
    end

    test "leaving a group you are not in is still 200 (idempotent, like unfollow)" do
      Application.put_env(:sukhi_api, :fake_social, %{
        leave_group: {:error, :not_found},
        list_relationships: [%{id: 2, following: false}]
      })

      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/2/leave"))

      assert resp.status == 200
    end

    test "gateway unreachable → 503" do
      {:ok, resp} = Router.handle(authed_post("/api/v1-bonfire/groups/2/leave"))

      assert resp.status == 503
      assert JSON.decode!(resp.body) == %{"error" => "gateway_not_connected"}
    end
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, value), do: Application.put_env(:sukhi_api, key, value)
end
