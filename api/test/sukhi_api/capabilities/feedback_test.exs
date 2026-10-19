# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.FeedbackTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  # Records what the capability sends the gateway, answers from :fake_feedback.
  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.Feedback, fun, args, _t) do
      send(Application.fetch_env!(:sukhi_api, :fake_feedback_pid), {:rpc, fun, args})
      table = Application.get_env(:sukhi_api, :fake_feedback, %{})
      {:ok, Map.fetch!(table, fun)}
    end

    def call(SukhiFedi.OAuth, :verify_bearer, _args, _t),
      do: {:ok, Application.get_env(:sukhi_api, :fake_oauth)}

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  setup do
    prev = for k <- [:gateway_rpc_impl, :enabled_addons, :fake_feedback, :fake_oauth], do: {k, Application.get_env(:sukhi_api, k)}

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_feedback_pid, self())

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:sukhi_api, k)
        {k, v} -> Application.put_env(:sukhi_api, k, v)
      end)

      Application.delete_env(:sukhi_api, :fake_feedback_pid)
    end)
  end

  defp account(id, admin?), do: %{id: id, username: "u#{id}", is_admin: admin?}

  defp as(account, scopes) do
    Application.put_env(:sukhi_api, :fake_oauth, {:ok, %{account: account, app: %{id: 1}, scopes: scopes}})
    [{"authorization", "Bearer t"}, {"content-type", "application/json"}]
  end

  defp post_feedback(body, headers \\ [{"content-type", "application/json"}]) do
    Router.handle(%{method: "POST", path: "/api/v1/feedback", headers: headers, body: JSON.encode!(body)})
  end

  defp item(overrides) do
    Map.merge(
      %{
        id: 5,
        body: "hello",
        screen: "timeline",
        lang: "ja",
        version: "1.2.3",
        account_id: nil,
        handled_at: nil,
        handled_by_id: nil,
        created_at: ~U[2026-10-19 00:00:00Z]
      },
      overrides
    )
  end

  describe "POST /api/v1/feedback" do
    test "anonymous: 202 with an opaque id, account_id nil, only the four fields forwarded" do
      Application.put_env(:sukhi_api, :fake_feedback, %{submit: {:ok, item(%{id: 77})}})

      {:ok, resp} =
        post_feedback(%{"body" => "hi", "screen" => "timeline", "lang" => "ja", "version" => "1", "account_id" => 9, "ip" => "1.2.3.4"})

      assert resp.status == 202
      assert JSON.decode!(resp.body) == %{"id" => "77"}

      assert_received {:rpc, :submit, [attrs, nil]}
      assert attrs == %{"body" => "hi", "screen" => "timeline", "lang" => "ja", "version" => "1"}
    end

    test "valid token: the account id is recorded" do
      Application.put_env(:sukhi_api, :fake_feedback, %{submit: {:ok, item(%{id: 1})}})
      headers = as(account(42, false), ["read"])

      {:ok, resp} = post_feedback(%{"body" => "hi"}, headers)

      assert resp.status == 202
      assert_received {:rpc, :submit, [_attrs, 42]}
    end

    test "validation failure from the changeset is a 422 with an error" do
      cs = %{errors: [body: {"should be at most 2000 character(s)", []}]}
      Application.put_env(:sukhi_api, :fake_feedback, %{submit: {:error, cs}})

      {:ok, resp} = post_feedback(%{"body" => String.duplicate("a", 2001)})

      assert resp.status == 422
      body = JSON.decode!(resp.body)
      assert is_binary(body["error"])
      assert body["details"]["body"] =~ "2000"
    end

    test "a body that is not a JSON object is handed over empty (the changeset says no)" do
      cs = %{errors: [body: {"can't be blank", []}]}
      Application.put_env(:sukhi_api, :fake_feedback, %{submit: {:error, cs}})

      {:ok, resp} = Router.handle(%{method: "POST", path: "/api/v1/feedback", headers: [], body: "[1]"})

      assert resp.status == 422
      assert_received {:rpc, :submit, [%{}, nil]}
    end
  end

  describe "GET /api/v1/admin/feedback" do
    test "no token → 401" do
      {:ok, resp} = Router.handle(%{method: "GET", path: "/api/v1/admin/feedback", headers: []})
      assert resp.status == 401
    end

    test "non-admin with the scope → 403 admin_required" do
      headers = as(account(2, false), ["admin:read"])
      {:ok, resp} = Router.handle(%{method: "GET", path: "/api/v1/admin/feedback", headers: headers, query: ""})
      assert resp.status == 403
      assert JSON.decode!(resp.body)["error"] == "admin_required"
    end

    test "admin without the scope → 403 insufficient_scope" do
      headers = as(account(1, true), ["read"])
      {:ok, resp} = Router.handle(%{method: "GET", path: "/api/v1/admin/feedback", headers: headers, query: ""})
      assert resp.status == 403
      assert JSON.decode!(resp.body)["error"] == "insufficient_scope"
    end

    test "admin: items + pagination, handled filter forwarded" do
      Application.put_env(:sukhi_api, :fake_feedback, %{list: {[item(%{id: 6, account_id: 3}), item(%{})], 2}})
      headers = as(account(1, true), ["admin:read"])

      {:ok, resp} =
        Router.handle(%{method: "GET", path: "/api/v1/admin/feedback", headers: headers, query: "handled=false"})

      assert resp.status == 200
      body = JSON.decode!(resp.body)
      assert [%{"id" => "6", "account_id" => "3", "handled_at" => nil}, %{"id" => "5"}] = body["items"]
      assert body["pagination"]["total"] == 2
      assert_received {:rpc, :list, [%{limit: 20, offset: 0}, false]}
    end
  end

  describe "POST /api/v1/admin/feedback/:id/handled" do
    test "admin marks it handled" do
      Application.put_env(:sukhi_api, :fake_feedback, %{
        mark_handled: {:ok, item(%{handled_at: ~U[2026-10-19 01:00:00Z], handled_by_id: 1})}
      })

      headers = as(account(1, true), ["admin:write"])
      {:ok, resp} = Router.handle(%{method: "POST", path: "/api/v1/admin/feedback/5/handled", headers: headers, body: ""})

      assert resp.status == 200
      assert JSON.decode!(resp.body)["handled_at"] == "2026-10-19T01:00:00Z"
      assert_received {:rpc, :mark_handled, ["5", 1]}
    end

    test "unknown id is 404; non-admin is 403" do
      Application.put_env(:sukhi_api, :fake_feedback, %{mark_handled: {:error, :not_found}})
      headers = as(account(1, true), ["admin:write"])
      {:ok, resp} = Router.handle(%{method: "POST", path: "/api/v1/admin/feedback/9/handled", headers: headers, body: ""})
      assert resp.status == 404

      headers = as(account(2, false), ["admin:write"])
      {:ok, resp} = Router.handle(%{method: "POST", path: "/api/v1/admin/feedback/9/handled", headers: headers, body: ""})
      assert resp.status == 403
    end
  end
end
