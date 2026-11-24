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

  # 頁はここに無い(front の仕事)。ここが答えるのは「何を見せるか」の決定だけ。
  @decide "/api/v1/sukhi/oauth/authorize"

  defp decide(query, headers \\ []),
    do: Router.handle(%{method: "GET", path: @decide, query: query, headers: headers})

  defp body(resp), do: JSON.decode!(resp.body)

  defp set_cookies(resp), do: for({"set-cookie", v} <- resp.headers, do: v)

  describe "GET /api/v1/sukhi/oauth/authorize" do
    test "missing client_id → 400 invalid_request" do
      {:ok, resp} = decide("redirect_uri=foo&response_type=code")

      assert resp.status == 400
      assert {"content-type", "application/json"} in resp.headers
      assert %{"error" => "invalid_request"} = body(resp)
    end

    test "response_type other than code → 400" do
      {:ok, resp} = decide("client_id=c&response_type=token")

      assert resp.status == 400
      assert %{"error" => "unsupported_response_type"} = body(resp)
    end

    test "no session cookie → decision login (no consent for someone not signed in)" do
      {:ok, resp} =
        decide("client_id=cid&redirect_uri=https://example.com/cb&response_type=code")

      assert resp.status == 200
      assert body(resp) == %{"decision" => "login"}
    end

    test "unknown client_id → 404 invalid_client" do
      Application.put_env(:sukhi_api, :fake_sessions, %{"sess_token" => %{id: 1, username: "alice"}})
      Application.put_env(:sukhi_api, :fake_oauth, %{find_app_by_client_id: {:error, :not_found}})

      {:ok, resp} =
        decide("client_id=nope&redirect_uri=https://example.com/cb", [{"cookie", "session_token=sess_token"}])

      assert resp.status == 404
      assert %{"error" => "invalid_client"} = body(resp)
    end

    test "gateway not connected → 503, said as the other endpoints say it" do
      Application.put_env(:sukhi_api, :fake_sessions, %{"sess_token" => %{id: 1, username: "alice"}})

      {:ok, resp} =
        decide("client_id=cid&redirect_uri=https://example.com/cb", [{"cookie", "session_token=sess_token"}])

      assert resp.status == 503
      assert %{"error" => "gateway_not_connected"} = body(resp)
    end

    test "known client, valid session, non-first-party redirect → decision consent" do
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
        decide(
          "client_id=cid_in_form&redirect_uri=https://example.com/cb&scope=read&response_type=code&state=xyz",
          [{"cookie", "session_token=sess_token"}]
        )

      assert resp.status == 200

      assert body(resp) == %{
               "decision" => "consent",
               "app" => %{"name" => "ConsentApp", "client_id" => "cid_in_form"},
               "scopes" => ["read"],
               "account" => %{"username" => "alice"}
             }

      # 同意の前には、コードを作らない(create_authorization_code は設定していない ── 呼ばれれば 503 になる)。
      assert set_cookies(resp) == []
    end

    test "admin scope asked by an account that is not an admin → denied (who, and why), no consent" do
      Application.put_env(:sukhi_api, :fake_sessions, %{
        "sess" => %{id: 5, username: "alice", is_admin: false}
      })

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "gov", client_id: "c", redirect_uri: "https://gov.example/"}}
      })

      {:ok, resp} =
        decide("client_id=c&redirect_uri=https://gov.example/&scope=admin:read+admin:write&response_type=code", [
          {"cookie", "session_token=sess"}
        ])

      assert resp.status == 200

      assert body(resp) == %{
               "decision" => "denied",
               "reason" => "admin_required",
               "account" => %{"username" => "alice"}
             }
    end

    test "admin scope asked by an admin gets the consent, with who is signed in" do
      Application.put_env(:sukhi_api, :fake_sessions, %{
        "sess" => %{id: 1, username: "kuro_admin", is_admin: true}
      })

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "gov", client_id: "c", redirect_uri: "https://gov.example/"}}
      })

      {:ok, resp} =
        decide("client_id=c&redirect_uri=https://gov.example/&scope=admin:read&response_type=code", [
          {"cookie", "session_token=sess"}
        ])

      assert %{"decision" => "consent", "scopes" => ["admin:read"], "account" => %{"username" => "kuro_admin"}} =
               body(resp)
    end

    test "scopes come as a list of names, split on space or +, once each" do
      Application.put_env(:sukhi_api, :fake_sessions, %{"t" => %{id: 1, username: "alice"}})

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "App", client_id: "c", redirect_uri: "https://example.com/cb"}}
      })

      {:ok, resp} =
        decide("client_id=c&redirect_uri=https://example.com/cb&scope=read+write:statuses%20read%20push", [
          {"cookie", "session_token=t"}
        ])

      assert %{"scopes" => ["read", "write:statuses", "push"]} = body(resp)
    end

    test "first-party redirect_uri (our own host) skips consent: the code is minted, decision redirect" do
      Application.put_env(:sukhi_api, :fake_sessions, %{"t" => %{id: 5, username: "alice"}})

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "web", client_id: "c", redirect_uri: "http://localhost:4000/app/callback"}},
        create_authorization_code: {:ok, %{code: "first_party_code", state: "st"}}
      })

      {:ok, resp} =
        decide("client_id=c&redirect_uri=http://localhost:4000/app/callback&scope=read&state=st", [
          {"cookie", "session_token=t"}
        ])

      assert resp.status == 200
      assert %{"decision" => "redirect", "location" => location} = body(resp)
      assert location =~ "http://localhost:4000/app/callback?"
      assert location =~ "code=first_party_code"
      assert location =~ "state=st"
    end

    test "a redirect_uri the app did not register is refused at minting (400)" do
      Application.put_env(:sukhi_api, :fake_sessions, %{"t" => %{id: 5, username: "alice"}})

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "web", client_id: "c", redirect_uri: "http://localhost:4000/cb"}}
      })

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "web", client_id: "c", redirect_uri: "http://localhost:4000/cb"}},
        create_authorization_code: {:error, :invalid_redirect_uri}
      })

      {:ok, resp} =
        decide("client_id=c&redirect_uri=http://localhost:4000/evil", [{"cookie", "session_token=t"}])

      assert resp.status == 400
      assert %{"error" => "invalid_redirect_uri"} = body(resp)
    end

    test "a dead duplicate session_token before the live one does not bounce to login" do
      # ブラウザは同名 session_token を二つ持ちうる(古い host-only +
      # 新しい Domain)。先頭が死んでいても、生きた方を採る。
      Application.put_env(:sukhi_api, :fake_sessions, %{
        "live_session" => %{id: 7, username: "kuro43_"}
      })

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id:
          {:ok, %{id: 1, name: "App", client_id: "c", redirect_uri: "https://example.com/cb"}}
      })

      {:ok, resp} =
        decide("client_id=c&redirect_uri=https://example.com/cb&scope=read&response_type=code", [
          {"cookie", "session_token=stale_dead; session_token=live_session"}
        ])

      assert resp.status == 200
      assert %{"decision" => "consent", "app" => %{"name" => "App"}} = body(resp)
    end

    test "two live duplicate session_token cookies and nothing else → pick" do
      Application.put_env(:sukhi_api, :fake_sessions, %{
        "tok_alice" => %{id: 1, username: "alice"},
        "tok_bob" => %{id: 2, username: "bob"}
      })

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id:
          {:ok, %{id: 1, name: "App", client_id: "c", redirect_uri: "https://example.com/cb"}}
      })

      {:ok, resp} =
        decide("client_id=c&redirect_uri=https://example.com/cb&scope=read&response_type=code", [
          {"cookie", "session_token=tok_alice; session_token=tok_bob"}
        ])

      assert resp.status == 200
      assert %{"decision" => "pick", "accounts" => accounts} = body(resp)
      assert Enum.sort_by(accounts, & &1["id"]) == [%{"id" => 1, "username" => "alice"}, %{"id" => 2, "username" => "bob"}]
    end
  end

  describe "GET /api/v1/sukhi/oauth/authorize with multiple accounts" do
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

    @two "client_id=c&redirect_uri=https://example.com/cb&scope=read&response_type=code"
    @two_cookie [{"cookie", "session_token=tok_alice; session_tokens=extras_ab"}]

    test "two sessions → pick, not consent" do
      {:ok, resp} = decide(@two, @two_cookie)

      assert resp.status == 200
      assert %{"decision" => "pick", "accounts" => accounts} = body(resp)
      assert Enum.map(accounts, & &1["username"]) |> Enum.sort() == ["alice", "bob"]
      assert set_cookies(resp) == []
    end

    test "choosing an account promotes it and goes straight to consent, cookies swapped" do
      {:ok, resp} = decide(@two <> "&choose=2", @two_cookie)

      assert resp.status == 200
      assert %{"decision" => "consent", "app" => %{"name" => "TwoApp"}} = body(resp)

      cookies = set_cookies(resp)
      assert Enum.any?(cookies, &String.starts_with?(&1, "session_token=tok_bob;"))
      assert Enum.any?(cookies, &String.starts_with?(&1, "session_tokens=tok_alice;"))
    end

    test "choosing an unknown/stale id falls back to pick" do
      {:ok, resp} = decide(@two <> "&choose=999", @two_cookie)

      assert resp.status == 200
      assert %{"decision" => "pick"} = body(resp)
    end

    test "choose that is not a number is the same as one that is not there (no crash)" do
      {:ok, resp} = decide(@two <> "&choose=abc", @two_cookie)

      assert resp.status == 200
      assert %{"decision" => "pick"} = body(resp)
    end
  end

  describe "POST /api/v1/sukhi/oauth/authorize" do
    defp approve(headers, body),
      do: Router.handle(%{method: "POST", path: @decide, headers: headers, body: body})

    @json {"content-type", "application/json"}

    test "no session cookie → 401 unauthorized" do
      {:ok, resp} =
        approve([@json], JSON.encode!(%{client_id: "c", redirect_uri: "https://example.com/cb", scope: "read", state: "xyz"}))

      assert resp.status == 401
      assert %{"error" => "unauthorized"} = body(resp)
    end

    test "missing client_id → 400" do
      {:ok, resp} = approve([@json, {"cookie", "session_token=x"}], JSON.encode!(%{redirect_uri: "https://example.com/cb"}))

      assert resp.status == 400
      assert %{"error" => "invalid_request"} = body(resp)
    end

    test "valid session → decision redirect, carrying the code and state" do
      Application.put_env(:sukhi_api, :fake_sessions, %{
        "good_session" => %{id: 11, username: "alice"}
      })

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "x", client_id: "c", redirect_uri: "https://example.com/cb"}},
        create_authorization_code: {:ok, %{code: "auth_code_123", state: "xyz"}}
      })

      {:ok, resp} =
        approve(
          [@json, {"cookie", "session_token=good_session"}],
          JSON.encode!(%{client_id: "c", redirect_uri: "https://example.com/cb", scope: "read", state: "xyz"})
        )

      assert resp.status == 200
      assert %{"decision" => "redirect", "location" => location} = body(resp)
      assert location =~ "https://example.com/cb"
      assert location =~ "code=auth_code_123"
      assert location =~ "state=xyz"
    end

    test "the PKCE challenge goes to the gateway exactly as asked; a bad one is a 400" do
      app = %{id: 1, name: "gov", client_id: "c", redirect_uri: "https://gov.example/"}
      alice = %{id: 11, username: "alice"}
      ch = String.duplicate("A", 43)
      Application.put_env(:sukhi_api, :fake_sessions, %{"good_session" => alice})

      # この形の引数でしか答えない ── challenge が落ちたり形が変わったりすれば、not_connected(503)になる。
      Application.put_env(:sukhi_api, :fake_oauth, %{
        :find_app_by_client_id => {:ok, app},
        {:create_authorization_code,
         [
           app,
           alice,
           %{
             "code_challenge" => ch,
             "code_challenge_method" => "S256",
             redirect_uri: "https://gov.example/",
             scopes: "admin:read",
             state: "s"
           }
         ]} => {:ok, %{code: "pk", state: "s"}}
      })

      {:ok, resp} =
        approve(
          [@json, {"cookie", "session_token=good_session"}],
          JSON.encode!(%{
            client_id: "c",
            redirect_uri: "https://gov.example/",
            scope: "admin:read",
            state: "s",
            code_challenge: ch,
            code_challenge_method: "S256"
          })
        )

      assert resp.status == 200
      assert %{"location" => "https://gov.example/?" <> q} = body(resp)
      assert q =~ "code=pk"

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, app},
        create_authorization_code: {:error, :invalid_request}
      })

      {:ok, bad} =
        approve(
          [@json, {"cookie", "session_token=good_session"}],
          JSON.encode!(%{client_id: "c", redirect_uri: "https://gov.example/", code_challenge: "x", code_challenge_method: "plain"})
        )

      assert bad.status == 400
      assert %{"error" => "invalid_request"} = body(bad)
    end

    test "the gateway's admin_required on approving is a 403 the page can name" do
      Application.put_env(:sukhi_api, :fake_sessions, %{"good_session" => %{id: 11, username: "alice"}})

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "gov", client_id: "c", redirect_uri: "https://gov.example/"}},
        create_authorization_code: {:error, :admin_required}
      })

      {:ok, resp} =
        approve(
          [@json, {"cookie", "session_token=good_session"}],
          JSON.encode!(%{client_id: "c", redirect_uri: "https://gov.example/", scope: "admin:read"})
        )

      assert resp.status == 403
      assert %{"error" => "admin_required"} = body(resp)
    end

    test "a custom-scheme redirect (a phone app's) is carried through as it is" do
      Application.put_env(:sukhi_api, :fake_sessions, %{"good_session" => %{id: 11, username: "alice"}})

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "x", client_id: "c", redirect_uri: "cx-c3-toot://oauth"}},
        create_authorization_code: {:ok, %{code: "abc", state: nil}}
      })

      {:ok, resp} =
        approve(
          [@json, {"cookie", "session_token=good_session"}],
          JSON.encode!(%{client_id: "c", redirect_uri: "cx-c3-toot://oauth", scope: "read"})
        )

      assert %{"decision" => "redirect", "location" => "cx-c3-toot://oauth?code=abc"} = body(resp)
    end

    test "form-encoded body is still read (older callers)" do
      Application.put_env(:sukhi_api, :fake_sessions, %{"good_session" => %{id: 11, username: "alice"}})

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "x", client_id: "c", redirect_uri: "https://example.com/cb"}},
        create_authorization_code: {:ok, %{code: "auth_code_123", state: "xyz"}}
      })

      {:ok, resp} =
        approve(
          [{"content-type", "application/x-www-form-urlencoded"}, {"cookie", "session_token=good_session"}],
          "client_id=c&redirect_uri=https%3A%2F%2Fexample.com%2Fcb&scope=read&state=xyz"
        )

      assert %{"decision" => "redirect", "location" => location} = body(resp)
      assert location =~ "code=auth_code_123"
    end

    test "a dead duplicate session_token before the live one still authorizes" do
      Application.put_env(:sukhi_api, :fake_sessions, %{
        "live_session" => %{id: 11, username: "alice"}
      })

      Application.put_env(:sukhi_api, :fake_oauth, %{
        find_app_by_client_id: {:ok, %{id: 1, name: "x", client_id: "c", redirect_uri: "https://example.com/cb"}},
        create_authorization_code: {:ok, %{code: "auth_code_123", state: "xyz"}}
      })

      {:ok, resp} =
        approve(
          [@json, {"cookie", "session_token=stale_dead; session_token=live_session"}],
          JSON.encode!(%{client_id: "c", redirect_uri: "https://example.com/cb", scope: "read", state: "xyz"})
        )

      assert %{"decision" => "redirect", "location" => location} = body(resp)
      assert location =~ "code=auth_code_123"
      assert location =~ "state=xyz"
    end

    test "unknown client → 404 invalid_client" do
      Application.put_env(:sukhi_api, :fake_sessions, %{"good_session" => %{id: 11, username: "alice"}})
      Application.put_env(:sukhi_api, :fake_oauth, %{find_app_by_client_id: {:error, :not_found}})

      {:ok, resp} =
        approve(
          [@json, {"cookie", "session_token=good_session"}],
          JSON.encode!(%{client_id: "nope", redirect_uri: "https://example.com/cb"})
        )

      assert resp.status == 404
      assert %{"error" => "invalid_client"} = body(resp)
    end
  end

  # 頁は、もう api には無い。古い道を叩いても、HTML は返らない。
  test "the old /oauth/authorize is not here any more (no page)" do
    {:ok, resp} = Router.handle(%{method: "GET", path: "/oauth/authorize", query: "client_id=c", headers: []})

    assert resp.status == 404
    assert {"content-type", "application/json"} in resp.headers
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, value), do: Application.put_env(:sukhi_api, key, value)
end
