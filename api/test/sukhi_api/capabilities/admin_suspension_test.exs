# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.AdminSuspensionTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  # Answers from :fake_suspension and tells the test what the capability asked.
  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.OAuth, :verify_bearer, _args, _t) do
      {:ok, Application.fetch_env!(:sukhi_api, :fake_bearer)}
    end

    def call(SukhiFedi.Fedi.DeliverySuspension.Admin, fun, args, _t) do
      send(Application.fetch_env!(:sukhi_api, :fake_pid), {:rpc, fun, args})
      table = Application.get_env(:sukhi_api, :fake_suspension, %{})
      {:ok, Map.fetch!(table, fun)}
    end

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  setup do
    keys = [:gateway_rpc_impl, :enabled_addons, :fake_suspension, :fake_bearer, :fake_pid]
    prev = for k <- keys, do: {k, Application.get_env(:sukhi_api, k)}

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_pid, self())

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:sukhi_api, k)
        {k, v} -> Application.put_env(:sukhi_api, k, v)
      end)
    end)
  end

  defp answer(table), do: Application.put_env(:sukhi_api, :fake_suspension, table)
  defp account(admin?), do: %{id: 9, username: "kuro", is_admin: admin?}

  defp call(method, path, scopes, account, body \\ nil) do
    Application.put_env(
      :sukhi_api,
      :fake_bearer,
      {:ok, %{account: account, app: %{id: 7, name: "test"}, scopes: scopes}}
    )

    Router.handle(%{
      method: method,
      path: path,
      headers: [{"authorization", "Bearer t"}, {"content-type", "application/json"}],
      body: if(body, do: JSON.encode!(body), else: "")
    })
  end

  defp json({:ok, resp}), do: {resp.status, JSON.decode!(resp.body)}

  defp row(extra \\ %{}) do
    Map.merge(
      %{
        id: "https://rest.example/suspensions/1",
        controller: "https://rest.example/users/ops",
        target_kind: :origin,
        target: "https://us.example",
        revision: 2,
        status: :active,
        published: ~U[2026-11-28 08:00:00Z],
        effective_start: ~U[2026-11-28 09:00:00Z],
        effective_end: ~U[2026-11-28 12:00:00Z],
        in_effect: true,
        ignored: false,
        ignored_at: nil,
        summary: "<p>maintenance</p>",
        url: "https://rest.example/status",
        evidence: %{
          verified_at: ~U[2026-11-28 09:01:00Z],
          attempted_at: ~U[2026-11-28 09:01:00Z],
          failure: nil
        },
        held: 3
      },
      extra
    )
  end

  @list "/api/admin/delivery_suspensions"

  describe "who may" do
    test "no token → 401" do
      {:ok, resp} = Router.handle(%{method: "GET", path: @list, headers: []})
      assert resp.status == 401
    end

    test "a token that can only read cannot choose" do
      for action <- ["ignore", "unignore"] do
        assert {403, %{"error" => "insufficient_scope"}} =
                 json(call("POST", "#{@list}/#{action}", ["admin:read"], account(true), %{id: "x"}))
      end

      refute_received {:rpc, _, _}
    end

    test "the right scope on an account that is not an admin → 403, nothing asked" do
      assert {403, %{"error" => "admin_required"}} =
               json(call("GET", @list, ["admin:read"], account(false)))

      assert {403, %{"error" => "admin_required"}} =
               json(call("POST", "#{@list}/ignore", ["admin:write"], account(false), %{id: "x"}))

      refute_received {:rpc, :list, _}
      refute_received {:rpc, :ignore, _}
    end
  end

  describe "GET list" do
    test "what the screen needs: controller, target, revision, end, evidence, ignored" do
      answer(%{list: {:ok, [row(), row(%{id: "b", ignored: true, in_effect: false, evidence: nil})]}})

      assert {200, %{"suspensions" => [first, second]}} =
               json(call("GET", @list, ["admin:read"], account(true)))

      assert first["id"] == "https://rest.example/suspensions/1"
      assert first["controller"] == "https://rest.example/users/ops"
      assert first["target_kind"] == "origin"
      assert first["revision"] == 2
      assert first["effective_end"] == "2026-11-28T12:00:00Z"
      assert first["in_effect"] == true
      assert first["held"] == 3
      assert first["evidence"]["verified_at"] == "2026-11-28T09:01:00Z"
      assert first["summary"] == "<p>maintenance</p>"
      assert first["url"] == "https://rest.example/status"
      assert second["ignored"] == true
      assert second["evidence"] == nil
    end
  end

  describe "ignore / unignore" do
    test "the id goes to the gateway with who chose; the answer says where it stands" do
      answer(%{ignore: :ok, unignore: :ok})

      assert {200, %{"id" => "n1", "ignored" => true}} =
               json(call("POST", "#{@list}/ignore", ["admin:write"], account(true), %{id: "n1"}))

      assert_received {:rpc, :ignore, ["n1", 9]}

      assert {200, %{"ignored" => false}} =
               json(call("POST", "#{@list}/unignore", ["admin:write"], account(true), %{id: "n1"}))

      assert_received {:rpc, :unignore, ["n1", 9]}
    end

    test "a notice we do not have is 404; a body with no id is 400, nothing asked" do
      answer(%{ignore: {:error, :not_found}})

      assert {404, %{"error" => "suspension_not_found"}} =
               json(call("POST", "#{@list}/ignore", ["admin:write"], account(true), %{id: "none"}))

      assert {400, %{"error" => "bad_request"}} =
               json(call("POST", "#{@list}/ignore", ["admin:write"], account(true), %{}))

      refute_received {:rpc, :ignore, [nil | _]}
    end
  end
end
