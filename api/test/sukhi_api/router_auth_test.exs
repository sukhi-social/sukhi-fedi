# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.RouterAuthTest do
  @moduledoc """
  Tests the auth plug behavior in `SukhiApi.Router` against real
  capability routes shipped in lib/. The Registry only discovers
  lib/ modules, so we exercise:

    * `GET  /api/v1/instance` — 3-tuple, unauthenticated
    * `POST /api/v1/apps`     — 3-tuple, unauthenticated
    * `POST /api/v1/apps/verify_credentials` — scope: "read"
    * `GET  /api/v1/accounts/verify_credentials` — scope: "read:accounts"
  """

  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    # Plays back canned `verify_bearer/1` responses keyed by token.
    # Tests `Application.put_env(:sukhi_api, :fake_rpc, %{token => response})`
    # before calling Router.handle/1.
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.OAuth, :verify_bearer, [token], _timeout) do
      table = Application.get_env(:sukhi_api, :fake_rpc, %{})

      case Map.get(table, token, :not_configured) do
        :not_configured -> {:error, :not_connected}
        canned -> {:ok, canned}
      end
    end

    # The session cookie's lookup, keyed the same way under `:fake_sessions`
    # (token => account or nil).
    def call(SukhiFedi.Accounts, :get_account_by_session_token, [token], _timeout) do
      table = Application.get_env(:sukhi_api, :fake_sessions, %{})

      case Map.fetch(table, token) do
        {:ok, account} -> {:ok, account}
        :error -> {:error, :not_connected}
      end
    end

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  setup do
    prev_rpc = Application.get_env(:sukhi_api, :gateway_rpc_impl)
    prev_addons = Application.get_env(:sukhi_api, :enabled_addons)
    prev_table = Application.get_env(:sukhi_api, :fake_rpc)
    prev_sessions = Application.get_env(:sukhi_api, :fake_sessions)

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_rpc, %{})
    Application.put_env(:sukhi_api, :fake_sessions, %{})

    on_exit(fn ->
      restore(:gateway_rpc_impl, prev_rpc)
      restore(:enabled_addons, prev_addons)
      restore(:fake_rpc, prev_table)
      restore(:fake_sessions, prev_sessions)
    end)

    :ok
  end

  test "3-tuple route returns 200 without a token (GET /api/v1/instance)" do
    {:ok, resp} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/instance",
        headers: []
      })

    assert resp.status == 200
  end

  test "scoped route without Authorization header returns 401" do
    {:ok, resp} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/accounts/verify_credentials",
        headers: []
      })

    assert resp.status == 401
    assert JSON.decode!(resp.body)["error"] == "invalid_token"
  end

  test "valid token with sufficient scope (read:accounts) returns 200" do
    Application.put_env(:sukhi_api, :fake_rpc, %{
      "good" =>
        {:ok,
         %{
           account: %{
             id: 42,
             username: "alice",
             display_name: "Alice",
             summary: "hi",
             is_bot: false,
             avatar_url: nil,
             banner_url: nil,
             created_at: ~U[2026-01-01 00:00:00Z]
           },
           app: %{id: 7, name: "smoke"},
           scopes: ["read:accounts", "write"]
         }}
    })

    {:ok, resp} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/accounts/verify_credentials",
        headers: [{"authorization", "Bearer good"}]
      })

    assert resp.status == 200
    body = JSON.decode!(resp.body)
    assert body["id"] == "42"
    assert body["username"] == "alice"
  end

  test "scope superset (granted=[read:accounts, write], required=read:accounts) → 200" do
    Application.put_env(:sukhi_api, :fake_rpc, %{
      "scoped" =>
        {:ok,
         %{
           account: %{
             id: 1,
             username: "x",
             display_name: "X",
             summary: "",
             is_bot: false,
             avatar_url: nil,
             banner_url: nil,
             created_at: ~U[2026-01-01 00:00:00Z]
           },
           app: %{id: 1, name: "a"},
           scopes: ["read:accounts", "write"]
         }}
    })

    {:ok, resp} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/accounts/verify_credentials",
        headers: [{"authorization", "Bearer scoped"}]
      })

    assert resp.status == 200
  end

  test "scope mismatch (required=write:statuses, granted=read) → 403" do
    # `read` は read:* を覆う umbrella scope (oauth.ex / router.granted?/2)
    # なので、read granted で read:accounts を要求しても通る。本当に
    # 通らないペアを assert したいので、write:statuses を要求する
    # `POST /api/v1/statuses` に対して granted=[read] を当てる。
    Application.put_env(:sukhi_api, :fake_rpc, %{
      "narrow" =>
        {:ok,
         %{
           account: %{id: 1, username: "x"},
           app: %{id: 1, name: "a"},
           scopes: ["read"]
         }}
    })

    {:ok, resp} =
      Router.handle(%{
        method: "POST",
        path: "/api/v1/statuses",
        headers: [{"authorization", "Bearer narrow"}]
      })

    assert resp.status == 403
    body = JSON.decode!(resp.body)
    assert body["error"] == "insufficient_scope"
    assert body["scope"] == "write:statuses"
  end

  test "verify_bearer returned :invalid_token → 401" do
    Application.put_env(:sukhi_api, :fake_rpc, %{
      "bad" => {:error, :invalid_token}
    })

    {:ok, resp} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/accounts/verify_credentials",
        headers: [{"authorization", "Bearer bad"}]
      })

    assert resp.status == 401
  end

  test "gateway not connected → 503" do
    {:ok, resp} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/accounts/verify_credentials",
        headers: [{"authorization", "Bearer anything"}]
      })

    assert resp.status == 503
    assert JSON.decode!(resp.body)["error"] == "gateway_not_connected"
  end

  test "missing Bearer scheme → 401" do
    {:ok, resp} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/accounts/verify_credentials",
        headers: [{"authorization", "Basic foo"}]
      })

    assert resp.status == 401
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, value), do: Application.put_env(:sukhi_api, key, value)

  # ── the first-party cookie ────────────────────────────────────────────

  @alice %{
    id: 42,
    username: "alice",
    display_name: "Alice",
    summary: "hi",
    is_bot: false,
    avatar_url: nil,
    banner_url: nil,
    created_at: ~U[2026-01-01 00:00:00Z]
  }

  defp with_session(token, account),
    do: Application.put_env(:sukhi_api, :fake_sessions, %{token => account})

  test "session cookie alone is the viewer on a GET" do
    with_session("sess", @alice)

    {:ok, resp} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/accounts/verify_credentials",
        headers: [{"cookie", "theme=dark; session_token=sess"}]
      })

    assert resp.status == 200
    assert JSON.decode!(resp.body)["username"] == "alice"
  end

  test "a write on the cookie needs the same-site header: 403 without, through with" do
    with_session("sess", @alice)

    {:ok, without} =
      Router.handle(%{
        method: "POST",
        path: "/api/v1/markers",
        headers: [{"cookie", "session_token=sess"}],
        body: %{}
      })

    assert without.status == 403
    assert JSON.decode!(without.body)["error"] == "same_site_required"

    {:ok, with_header} =
      Router.handle(%{
        method: "POST",
        path: "/api/v1/markers",
        headers: [{"cookie", "session_token=sess"}, {"X-Requested-With", "natadeco"}],
        body: %{}
      })

    # Past the gate — the handler itself then hits the fake gateway (503),
    # which is not the auth layer's answer.
    refute with_header.status in [401, 403]
  end

  test "a cookie that no longer resolves is anonymous on a public route, 401 on a scoped one" do
    with_session("stale", nil)

    {:ok, public} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/instance",
        headers: [{"cookie", "session_token=stale"}]
      })

    assert public.status == 200

    {:ok, scoped} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/accounts/verify_credentials",
        headers: [{"cookie", "session_token=stale"}]
      })

    assert scoped.status == 401
  end

  test "a bearer wins over the cookie" do
    with_session("sess", @alice)
    Application.put_env(:sukhi_api, :fake_rpc, %{"bad" => {:error, :invalid_token}})

    {:ok, resp} =
      Router.handle(%{
        method: "GET",
        path: "/api/v1/accounts/verify_credentials",
        headers: [{"authorization", "Bearer bad"}, {"cookie", "session_token=sess"}]
      })

    assert resp.status == 401
  end

end
