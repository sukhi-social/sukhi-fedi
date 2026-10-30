# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonAccountPorterTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.AccountPorter, fun, args, _t) do
      send(self(), {:rpc, fun, args})
      table = Application.get_env(:sukhi_api, :fake_porter, %{})

      case Map.fetch(table, fun) do
        {:ok, v} -> {:ok, v}
        :error -> {:error, :not_connected}
      end
    end

    def call(SukhiFedi.OAuth, _fun, _args, _t) do
      {:ok, Application.get_env(:sukhi_api, :fake_oauth)}
    end

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  setup do
    prev = %{
      rpc: Application.get_env(:sukhi_api, :gateway_rpc_impl),
      addons: Application.get_env(:sukhi_api, :enabled_addons),
      porter: Application.get_env(:sukhi_api, :fake_porter),
      oauth: Application.get_env(:sukhi_api, :fake_oauth)
    }

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_porter, %{})

    Application.put_env(
      :sukhi_api,
      :fake_oauth,
      {:ok,
       %{
         account: %{id: 7, username: "alice", display_name: "A", summary: ""},
         app: %{id: 1, name: "x"},
         scopes: ["read:follows", "write:follows", "read:blocks", "read:mutes"]
       }}
    )

    on_exit(fn ->
      restore(:gateway_rpc_impl, prev.rpc)
      restore(:enabled_addons, prev.addons)
      restore(:fake_porter, prev.porter)
      restore(:fake_oauth, prev.oauth)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, v), do: Application.put_env(:sukhi_api, key, v)

  defp authed(method, path, body \\ "", type \\ "application/json") do
    %{
      method: method,
      path: path,
      headers: [{"authorization", "Bearer t"}, {"content-type", type}],
      body: body
    }
  end

  test "export answers the gateway's CSV as an attachment" do
    csv = "Account address\r\nbob@remote.example\r\n"
    Application.put_env(:sukhi_api, :fake_porter, %{export: csv})

    {:ok, resp} = Router.handle(authed("GET", "/api/v1/accounts/export/following"))

    assert resp.status == 200
    assert resp.body == csv
    assert {"content-type", "text/csv; charset=utf-8"} in resp.headers
    assert_received {:rpc, :export, [7, :following]}
  end

  test "export of blocks needs read:blocks — a token without it is refused" do
    Application.put_env(:sukhi_api, :fake_oauth, {:ok,
      %{account: %{id: 7, username: "a", display_name: "A", summary: ""}, app: %{id: 1, name: "x"}, scopes: ["read:follows"]}})

    {:ok, resp} = Router.handle(authed("GET", "/api/v1/accounts/export/blocks"))
    assert resp.status == 403
  end

  test "import takes JSON {data} and returns the gateway's counts" do
    result = %{imported: 2, skipped: 1, unresolved: ["ghost@nowhere.example"]}
    Application.put_env(:sukhi_api, :fake_porter, %{import_csv: result})

    {:ok, resp} =
      Router.handle(
        authed("POST", "/api/v1/accounts/import/following", JSON.encode!(%{data: "a@b.example\n"}))
      )

    assert resp.status == 200
    assert JSON.decode!(resp.body)["imported"] == 2
    assert_received {:rpc, :import_csv, [7, :following, "a@b.example\n"]}
  end

  test "import also takes the CSV itself as text/csv" do
    Application.put_env(:sukhi_api, :fake_porter, %{import_csv: %{imported: 0, skipped: 0, unresolved: []}})

    {:ok, resp} =
      Router.handle(authed("POST", "/api/v1/accounts/import/following", "x@y.example\n", "text/csv"))

    assert resp.status == 200
    assert_received {:rpc, :import_csv, [7, :following, "x@y.example\n"]}
  end

  test "import: gateway's :too_many becomes 422" do
    Application.put_env(:sukhi_api, :fake_porter, %{import_csv: {:error, :too_many}})

    {:ok, resp} =
      Router.handle(authed("POST", "/api/v1/accounts/import/following", JSON.encode!(%{data: "x"})))

    # RpcResult {:ok, {:error, :too_many}} — the capability matches the inner shape.
    assert resp.status == 422
  end

  test "no bearer → 401" do
    {:ok, resp} = Router.handle(%{method: "GET", path: "/api/v1/accounts/export/following", headers: []})
    assert resp.status == 401
  end
end
