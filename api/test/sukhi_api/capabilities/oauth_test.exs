# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.OAuthTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.OAuth, fun, args, _timeout) do
      table = Application.get_env(:sukhi_api, :fake_oauth, %{})

      case Map.get(table, {fun, args}, :not_configured) do
        :not_configured ->
          case Map.get(table, fun, :not_configured) do
            :not_configured -> {:error, :not_connected}
            canned -> {:ok, canned}
          end

        canned ->
          {:ok, canned}
      end
    end

    def call(SukhiFedi.Accounts, :get_account_by_session_token, [token], _timeout) do
      table = Application.get_env(:sukhi_api, :fake_sessions, %{})
      {:ok, Map.get(table, token)}
    end

    # Multi-account: a from-scratch reimplementation of SessionCookie's pure
    # layout math (it lives in the gateway's own mix project, not this one,
    # so there's nothing to delegate to here — same as the SukhiFedi.OAuth
    # fake above, which is canned rather than a real call). `fake_sessions`
    # doubles as the token→account table these draw from.
    def call(SukhiFedi.Web.Auth.SessionCookie, :decode_extra, [nil], _timeout), do: {:ok, []}

    def call(SukhiFedi.Web.Auth.SessionCookie, :decode_extra, [value], _timeout) do
      table = Application.get_env(:sukhi_api, :fake_extra_tokens, %{})
      {:ok, Map.get(table, value, [])}
    end

    def call(SukhiFedi.Web.Auth.SessionCookie, :resolve_all, [primary, extras], _timeout) do
      accounts = Application.get_env(:sukhi_api, :fake_sessions, %{})

      sessions =
        [{primary, true} | Enum.map(extras, &{&1, false})]
        |> Enum.reject(fn {t, _primary?} -> is_nil(t) end)
        |> Enum.map(fn {token, primary?} -> {token, primary?, Map.get(accounts, token)} end)
        |> Enum.reject(fn {_token, _primary?, account} -> is_nil(account) end)
        |> Enum.uniq_by(fn {_token, _primary?, account} -> account.id end)
        |> Enum.map(fn {token, primary?, account} -> %{account: account, token: token, primary?: primary?} end)

      {:ok, sessions}
    end

    def call(SukhiFedi.Web.Auth.SessionCookie, :layout_for_promote, [sessions, account_id], _timeout) do
      case Enum.find(sessions, &(&1.account.id == account_id)) do
        nil ->
          {:ok, :not_found}

        target ->
          others = sessions |> Enum.reject(&(&1.account.id == account_id)) |> Enum.map(& &1.token)
          {:ok, {target.token, others}}
      end
    end

    def call(SukhiFedi.Web.Auth.SessionCookie, :encode_extra, [tokens], _timeout) do
      {:ok, Enum.join(tokens, ",")}
    end
  end

  setup do
    prev_rpc = Application.get_env(:sukhi_api, :gateway_rpc_impl)
    prev_addons = Application.get_env(:sukhi_api, :enabled_addons)
    prev_oauth = Application.get_env(:sukhi_api, :fake_oauth)
    prev_sessions = Application.get_env(:sukhi_api, :fake_sessions)
    prev_extra_tokens = Application.get_env(:sukhi_api, :fake_extra_tokens)

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_oauth, %{})
    Application.put_env(:sukhi_api, :fake_sessions, %{})
    Application.put_env(:sukhi_api, :fake_extra_tokens, %{})

    on_exit(fn ->
      restore(:gateway_rpc_impl, prev_rpc)
      restore(:enabled_addons, prev_addons)
      restore(:fake_oauth, prev_oauth)
      restore(:fake_sessions, prev_sessions)
      restore(:fake_extra_tokens, prev_extra_tokens)
    end)

    :ok
  end

  describe "POST /oauth/token" do
    test "authorization_code grant returns token JSON" do
      Application.put_env(:sukhi_api, :fake_oauth, %{
        exchange_code_for_token:
          {:ok,
           %{
             access_token: "at_123",
             refresh_token: "rt_456",
             token_type: "Bearer",
             scope: "read write",
             created_at: 1_700_000_000
           }}
      })

      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/oauth/token",
          headers: [{"content-type", "application/json"}],
          body:
            JSON.encode!(%{
              "grant_type" => "authorization_code",
              "client_id" => "cid",
              "client_secret" => "sec",
              "code" => "code_xyz",
              "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
            })
        })

      assert resp.status == 200
      body = JSON.decode!(resp.body)
      assert body["access_token"] == "at_123"
      assert body["refresh_token"] == "rt_456"
      assert body["token_type"] == "Bearer"
      assert body["scope"] == "read write"
    end

    test "client_credentials grant returns token without refresh_token" do
      Application.put_env(:sukhi_api, :fake_oauth, %{
        client_credentials_grant:
          {:ok,
           %{
             access_token: "at_cc",
             refresh_token: nil,
             token_type: "Bearer",
             scope: "read",
             created_at: 1_700_000_000
           }}
      })

      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/oauth/token",
          headers: [{"content-type", "application/json"}],
          body:
            JSON.encode!(%{
              "grant_type" => "client_credentials",
              "client_id" => "cid",
              "client_secret" => "sec",
              "scope" => "read"
            })
        })

      assert resp.status == 200
      body = JSON.decode!(resp.body)
      assert body["access_token"] == "at_cc"
      refute Map.has_key?(body, "refresh_token")
    end

    test "invalid_grant returns 400 with error code" do
      Application.put_env(:sukhi_api, :fake_oauth, %{
        exchange_code_for_token: {:error, :invalid_grant}
      })

      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/oauth/token",
          headers: [{"content-type", "application/json"}],
          body:
            JSON.encode!(%{
              "grant_type" => "authorization_code",
              "client_id" => "cid",
              "client_secret" => "sec",
              "code" => "expired",
              "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
            })
        })

      assert resp.status == 400
      assert JSON.decode!(resp.body)["error"] == "invalid_grant"
    end

    test "unsupported grant type → 400 unsupported_grant_type" do
      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/oauth/token",
          headers: [{"content-type", "application/json"}],
          body: JSON.encode!(%{"grant_type" => "password"})
        })

      assert resp.status == 400
      assert JSON.decode!(resp.body)["error"] == "unsupported_grant_type"
    end

    test "form-encoded body is also accepted" do
      Application.put_env(:sukhi_api, :fake_oauth, %{
        client_credentials_grant:
          {:ok,
           %{
             access_token: "at_form",
             refresh_token: nil,
             token_type: "Bearer",
             scope: "read",
             created_at: 1
           }}
      })

      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/oauth/token",
          headers: [{"content-type", "application/x-www-form-urlencoded"}],
          body: "grant_type=client_credentials&client_id=cid&client_secret=sec&scope=read"
        })

      assert resp.status == 200
    end
  end

  describe "POST /oauth/revoke" do
    test "always returns 200 on success" do
      Application.put_env(:sukhi_api, :fake_oauth, %{revoke_token: :ok})

      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/oauth/revoke",
          headers: [{"content-type", "application/json"}],
          body: JSON.encode!(%{"client_id" => "c", "client_secret" => "s", "token" => "t"})
        })

      assert resp.status == 200
    end
  end

  describe "GET /oauth/authorize" do
    test "missing client_id → 400 HTML" do
      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/oauth/authorize",
          query: "redirect_uri=foo&response_type=code",
          headers: []
        })

      assert resp.status == 400
      assert {"content-type", "text/html; charset=utf-8"} in resp.headers
    end

    test "no session cookie → 302 to /login" do
      # GET /oauth/authorize は未ログインのとき consent を見せず、
      # /login に飛ばす(oauth.ex: redirect_to_login/1)。
      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/oauth/authorize",
          query: "client_id=cid&redirect_uri=https://example.com/cb&response_type=code",
          headers: []
        })

      assert resp.status == 302
      assert {"location", location} = List.keyfind(resp.headers, "location", 0)
      assert String.starts_with?(location, "/login?next=")
      assert location =~ "%2Foauth%2Fauthorize"
    end

    test "renders consent form for known client_id with a valid session and non-first-party redirect" do
      Application.put_env(:sukhi_api, :fake_sessions, %{
        "sess_token" => %{id: 1, username: "alice"}
      })

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id:
          {:ok,
           %{
             id: 1,
             name: "ConsentApp",
             client_id: "cid_in_form",
             redirect_uri: "https://example.com/cb"
           }}
      })

      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/oauth/authorize",
          query:
            "client_id=cid_in_form&redirect_uri=https://example.com/cb&scope=read&response_type=code&state=xyz",
          headers: [{"cookie", "session_token=sess_token"}]
        })

      assert resp.status == 200
      assert resp.body =~ "ConsentApp"
      assert resp.body =~ "cid_in_form"
      assert resp.body =~ "/oauth/authorize"

      # 同意フォームは外部アプリの custom scheme へ 302 で戻すので、
      # WebKit(Safari/iOS)が消してしまう `form-action 'self'` を
      # この応答だけ自前 CSP で外しておく(他の hardening は残す)。
      csp =
        Enum.find_value(resp.headers, fn
          {"content-security-policy", v} -> v
          _ -> nil
        end)

      assert csp, "consent form must set its own CSP so CorsPlug's form-action 'self' is not applied"
      refute csp =~ "form-action"
      assert csp =~ "frame-ancestors 'self'"
    end
  end

  describe "GET /oauth/authorize with multiple accounts" do
    setup do
      Application.put_env(:sukhi_api, :fake_sessions, %{
        "tok_alice" => %{id: 1, username: "alice"},
        "tok_bob" => %{id: 2, username: "bob"}
      })

      Application.put_env(:sukhi_api, :fake_extra_tokens, %{"extras_ab" => ["tok_bob"]})

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id:
          {:ok, %{id: 1, name: "TwoApp", client_id: "c", redirect_uri: "https://example.com/cb"}}
      })

      :ok
    end

    test "two sessions → a picker, not the consent form" do
      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/oauth/authorize",
          query: "client_id=c&redirect_uri=https://example.com/cb&scope=read&response_type=code",
          headers: [{"cookie", "session_token=tok_alice; session_tokens=extras_ab"}]
        })

      assert resp.status == 200
      assert resp.body =~ "@alice"
      assert resp.body =~ "@bob"
      assert resp.body =~ "choose=1"
      assert resp.body =~ "choose=2"
      refute resp.body =~ "TwoApp"
    end

    test "choosing an account promotes it and goes straight to consent, cookies swapped" do
      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/oauth/authorize",
          query: "client_id=c&redirect_uri=https://example.com/cb&scope=read&response_type=code&choose=2",
          headers: [{"cookie", "session_token=tok_alice; session_tokens=extras_ab"}]
        })

      assert resp.status == 200
      assert resp.body =~ "TwoApp"

      set_cookies = for {"set-cookie", v} <- resp.headers, do: v
      assert Enum.any?(set_cookies, &String.starts_with?(&1, "session_token=tok_bob;"))
      assert Enum.any?(set_cookies, &String.starts_with?(&1, "session_tokens=tok_alice;"))
    end

    test "choosing an unknown/stale id falls back to the picker" do
      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/oauth/authorize",
          query: "client_id=c&redirect_uri=https://example.com/cb&scope=read&response_type=code&choose=999",
          headers: [{"cookie", "session_token=tok_alice; session_tokens=extras_ab"}]
        })

      assert resp.status == 200
      assert resp.body =~ "@alice"
      assert resp.body =~ "@bob"
      refute resp.body =~ "TwoApp"
    end
  end

  describe "POST /oauth/authorize" do
    test "no session cookie → 401 HTML" do
      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/oauth/authorize",
          headers: [{"content-type", "application/x-www-form-urlencoded"}],
          body: "client_id=c&redirect_uri=https://example.com/cb&scope=read&state=xyz"
        })

      assert resp.status == 401
    end

    test "valid session redirects with code" do
      Application.put_env(:sukhi_api, :fake_sessions, %{
        "good_session" => %{id: 11, username: "alice"}
      })

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "x", client_id: "c", redirect_uri: "https://example.com/cb"}},
        create_authorization_code: {:ok, %{code: "auth_code_123", state: "xyz"}}
      })

      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/oauth/authorize",
          headers: [
            {"content-type", "application/x-www-form-urlencoded"},
            {"cookie", "session_token=good_session"}
          ],
          body: "client_id=c&redirect_uri=https%3A%2F%2Fexample.com%2Fcb&scope=read&state=xyz"
        })

      assert resp.status == 302

      location =
        Enum.find_value(resp.headers, fn {k, v} ->
          if String.downcase(k) == "location", do: v
        end)

      assert location =~ "https://example.com/cb"
      assert location =~ "code=auth_code_123"
      assert location =~ "state=xyz"
    end
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, value), do: Application.put_env(:sukhi_api, key, value)
end
