# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonAccountMigrationTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.AccountMigration, fun, args, _t), do: lookup(:fake_migration, fun, args)
    def call(SukhiFedi.OAuth, fun, args, _t), do: lookup(:fake_oauth, fun, args)
    def call(SukhiFedi.Accounts, fun, args, _t), do: lookup(:fake_accounts, fun, args)
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
      migration: Application.get_env(:sukhi_api, :fake_migration),
      accounts: Application.get_env(:sukhi_api, :fake_accounts),
      oauth: Application.get_env(:sukhi_api, :fake_oauth)
    }

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_migration, %{})

    Application.put_env(:sukhi_api, :fake_oauth, %{
      verify_bearer:
        {:ok,
         %{
           account: %{id: 7, username: "alice", display_name: "A", summary: ""},
           app: %{id: 1, name: "x"},
           scopes: ["read:accounts", "write:accounts"]
         }}
    })

    on_exit(fn ->
      restore(:gateway_rpc_impl, prev.rpc)
      restore(:enabled_addons, prev.addons)
      restore(:fake_migration, prev.migration)
      restore(:fake_accounts, prev.accounts)
      restore(:fake_oauth, prev.oauth)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, v), do: Application.put_env(:sukhi_api, key, v)

  defp authed(method, path, body) do
    %{
      method: method,
      path: path,
      headers: [{"authorization", "Bearer t"}, {"content-type", "application/json"}],
      body: body
    }
  end

  # verify_bearer は Ecto の構造体(Access を持たない)を返す。[]/["..."] で読むと落ちて 502 になった。
  describe "GET /api/v1/accounts/migration" do
    defmodule AccountStruct do
      defstruct id: 7, aliases: ["https://old.example/users/alice"], moved_to_uri: nil
    end

    # 認証 cache の account(60 秒古いことがある)ではなく、gateway の今の行を返す。
    test "reads aliases and moved_to from the gateway's current row, not the cached account" do
      Application.put_env(:sukhi_api, :fake_oauth, %{
        verify_bearer:
          {:ok,
           %{
             account: %AccountStruct{aliases: ["https://stale.example/users/alice"]},
             app: %{id: 1, name: "x"},
             scopes: ["read:accounts"]
           }}
      })

      Application.put_env(:sukhi_api, :fake_accounts, %{
        get_account: {:ok, %AccountStruct{aliases: ["https://fresh.example/users/alice"]}}
      })

      {:ok, resp} = Router.handle(authed("GET", "/api/v1/accounts/migration", ""))

      assert resp.status == 200

      assert JSON.decode!(resp.body) == %{
               "aliases" => ["https://fresh.example/users/alice"],
               "moved_to" => nil
             }
    end
  end

  describe "POST /api/v1/accounts/migration/aliases" do
    test "sets the alias list" do
      uri = "https://old.example/users/alice"
      Application.put_env(:sukhi_api, :fake_migration, %{set_aliases: {:ok, %{aliases: [uri]}}})

      {:ok, resp} =
        Router.handle(
          authed("POST", "/api/v1/accounts/migration/aliases", JSON.encode!(%{aliases: [uri]}))
        )

      assert resp.status == 200
      assert JSON.decode!(resp.body)["aliases"] == [uri]
    end

    test "an entry that cannot be resolved → 422 invalid_alias" do
      Application.put_env(:sukhi_api, :fake_migration, %{
        set_aliases: {:error, {:invalid_alias, "@ghost@nowhere.example"}}
      })

      {:ok, resp} =
        Router.handle(
          authed(
            "POST",
            "/api/v1/accounts/migration/aliases",
            JSON.encode!(%{aliases: ["@ghost@nowhere.example"]})
          )
        )

      assert resp.status == 422
      assert JSON.decode!(resp.body)["error"] == "invalid_alias"
    end
  end

  describe "POST /api/v1/accounts/migration/move" do
    test "consent missing → 422 target_must_alias_back" do
      Application.put_env(:sukhi_api, :fake_migration, %{move: {:error, :consent_missing}})

      {:ok, resp} =
        Router.handle(
          authed(
            "POST",
            "/api/v1/accounts/migration/move",
            JSON.encode!(%{target: "https://new.example/users/alice"})
          )
        )

      assert resp.status == 422
      assert JSON.decode!(resp.body)["error"] == "target_must_alias_back"
    end

    test "success → 200 with moved_to" do
      target = "https://new.example/users/alice"
      Application.put_env(:sukhi_api, :fake_migration, %{move: {:ok, %{moved_to_uri: target}}})

      {:ok, resp} =
        Router.handle(
          authed("POST", "/api/v1/accounts/migration/move", JSON.encode!(%{target: target}))
        )

      assert resp.status == 200
      assert JSON.decode!(resp.body)["moved_to"] == target
    end
  end

  test "no bearer → 401" do
    {:ok, resp} =
      Router.handle(%{method: "GET", path: "/api/v1/accounts/migration", headers: []})

    assert resp.status == 401
  end
end
