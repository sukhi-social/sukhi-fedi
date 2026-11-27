# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.OAuthTest do
  @moduledoc """
  End-to-end tests for `SukhiFedi.OAuth`. Requires the test Postgres
  with the OAuth migrations applied. Bring up the test stack and
  migrate before running:

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.OAuth
  alias SukhiFedi.Schema.{Account, OauthAccessToken, OauthApp, OauthAuthorizationCode, OutboxEvent}

  describe "register_app/1" do
    test "returns the app and a plaintext secret only once" do
      assert {:ok, %{app: app, client_secret: secret}} =
               OAuth.register_app(%{
                 "client_name" => "TestApp",
                 "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
                 "scopes" => "read write"
               })

      assert is_binary(app.client_id)
      assert is_binary(secret)
      # secret returned in plaintext; DB stores only its hash
      refute app.client_secret_hash == secret
      assert byte_size(secret) >= 32

      reloaded = SukhiFedi.AccountRepo.get!(OauthApp, app.id)
      assert reloaded.client_secret_hash == app.client_secret_hash
    end

    test "emits sns.outbox.oauth.app_registered" do
      {:ok, %{app: app}} =
        OAuth.register_app(%{
          "client_name" => "WithOutbox",
          "redirect_uris" => "https://example.com/cb",
          "scopes" => "read"
        })

      ev =
        SukhiFedi.AccountRepo.one!(
          from e in OutboxEvent,
            where: e.subject == "sns.outbox.oauth.app_registered" and e.aggregate_id == ^to_string(app.id)
        )

      assert ev.payload["app_id"] == app.id
      assert ev.payload["name"] == "WithOutbox"
    end
  end

  describe "verify_app_secret/2" do
    test "ok on match, error on mismatch" do
      {:ok, %{app: app, client_secret: secret}} = register("AuthApp")
      assert :ok = OAuth.verify_app_secret(app, secret)
      assert {:error, :invalid_client} = OAuth.verify_app_secret(app, "wrong-secret")
    end
  end

  describe "create_authorization_code/3" do
    test "rejects redirect_uri not in app's registered set" do
      {:ok, %{app: app}} = register("RedirAdmit", "https://a.example/cb https://b.example/cb")
      account = create_account!("u1")

      assert {:error, :invalid_redirect_uri} =
               OAuth.create_authorization_code(app, account, %{
                 redirect_uri: "https://evil.example/cb",
                 scopes: "read"
               })
    end

    test "rejects requested scope outside app's allowlist" do
      {:ok, %{app: app}} = register("ScopeApp", "x", "read")
      account = create_account!("u_scope")

      assert {:error, :invalid_scope} =
               OAuth.create_authorization_code(app, account, %{
                 redirect_uri: "x",
                 scopes: "admin"
               })
    end

    test "issues a code that can be exchanged exactly once" do
      {:ok, %{app: app, client_secret: secret}} = register("X1", "urn:ietf:wg:oauth:2.0:oob", "read write")
      account = create_account!("u_x1")

      assert {:ok, %{code: code}} =
               OAuth.create_authorization_code(app, account, %{
                 redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
                 scopes: "read"
               })

      assert {:ok, token1} =
               OAuth.exchange_code_for_token(%{
                 "client_id" => app.client_id,
                 "client_secret" => secret,
                 "code" => code,
                 "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
                 "grant_type" => "authorization_code"
               })

      assert is_binary(token1.access_token)
      assert is_binary(token1.refresh_token)

      # replay → invalid_grant
      assert {:error, :invalid_grant} =
               OAuth.exchange_code_for_token(%{
                 "client_id" => app.client_id,
                 "client_secret" => secret,
                 "code" => code,
                 "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
                 "grant_type" => "authorization_code"
               })
    end

    test "expired code → invalid_grant" do
      {:ok, %{app: app, client_secret: secret}} = register("Expiry", "urn:ietf:wg:oauth:2.0:oob")
      account = create_account!("u_expiry")

      {:ok, %{code: code}} =
        OAuth.create_authorization_code(app, account, %{
          redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
          scopes: "read"
        })

      # backdate
      _ =
        from(c in OauthAuthorizationCode,
          where: c.app_id == ^app.id
        )
        |> SukhiFedi.AccountRepo.update_all(set: [expires_at: ~U[2020-01-01 00:00:00Z]])

      assert {:error, :invalid_grant} =
               OAuth.exchange_code_for_token(%{
                 "client_id" => app.client_id,
                 "client_secret" => secret,
                 "code" => code,
                 "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
                 "grant_type" => "authorization_code"
               })
    end
  end

  describe "client_credentials_grant/3" do
    test "mints a token with account_id IS NULL" do
      {:ok, %{app: app, client_secret: secret}} = register("CC", "x", "read")

      assert {:ok, t} = OAuth.client_credentials_grant(app.client_id, secret, "read")
      assert is_binary(t.access_token)
      refute Map.get(t, :refresh_token)

      tok = SukhiFedi.AccountRepo.get_by!(OauthAccessToken, app_id: app.id)
      assert tok.account_id == nil
    end

    test "rejects invalid client" do
      assert {:error, :invalid_client} =
               OAuth.client_credentials_grant("nope", "nope", "read")
    end

    test "rejects scope outside app's allowlist" do
      {:ok, %{app: app, client_secret: secret}} = register("CC2", "x", "read")

      assert {:error, :invalid_scope} =
               OAuth.client_credentials_grant(app.client_id, secret, "admin")
    end
  end

  describe "verify_bearer/1" do
    test "returns account, app, and split scopes" do
      {:ok, %{app: app, client_secret: secret}} = register("VB", "urn:ietf:wg:oauth:2.0:oob", "read write")
      account = create_account!("u_vb")

      {:ok, %{code: code}} =
        OAuth.create_authorization_code(app, account, %{
          redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
          scopes: "read write"
        })

      {:ok, token} =
        OAuth.exchange_code_for_token(%{
          "client_id" => app.client_id,
          "client_secret" => secret,
          "code" => code,
          "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
          "grant_type" => "authorization_code"
        })

      assert {:ok, ctx} = OAuth.verify_bearer(token.access_token)
      assert ctx.account.id == account.id
      assert ctx.app.id == app.id
      assert "read" in ctx.scopes
      assert "write" in ctx.scopes
    end

    test "unknown token → :invalid_token" do
      assert {:error, :invalid_token} = OAuth.verify_bearer("garbage_no_match")
    end

    test "revoked token → :revoked" do
      {:ok, %{app: app, client_secret: secret}} = register("Rev", "x", "read")
      {:ok, t} = OAuth.client_credentials_grant(app.client_id, secret, "read")

      :ok =
        OAuth.revoke_token(%{
          "client_id" => app.client_id,
          "client_secret" => secret,
          "token" => t.access_token
        })

      assert {:error, :revoked} = OAuth.verify_bearer(t.access_token)
    end
  end

  describe "refresh_token_grant/1" do
    test "rotates the refresh token and revokes the old access token" do
      {:ok, %{app: app, client_secret: secret}} = register("RT", "urn:ietf:wg:oauth:2.0:oob")
      account = create_account!("u_rt")

      {:ok, %{code: code}} =
        OAuth.create_authorization_code(app, account, %{
          redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
          scopes: "read"
        })

      {:ok, t1} =
        OAuth.exchange_code_for_token(%{
          "client_id" => app.client_id,
          "client_secret" => secret,
          "code" => code,
          "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
          "grant_type" => "authorization_code"
        })

      {:ok, t2} =
        OAuth.refresh_token_grant(%{
          "client_id" => app.client_id,
          "client_secret" => secret,
          "refresh_token" => t1.refresh_token
        })

      refute t2.access_token == t1.access_token
      refute t2.refresh_token == t1.refresh_token

      # old access token is now revoked
      assert {:error, :revoked} = OAuth.verify_bearer(t1.access_token)
      assert {:ok, _} = OAuth.verify_bearer(t2.access_token)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  describe "token expiry (C5)" do
    test "minted tokens carry an absolute expiry and verify_bearer rejects an expired one" do
      {:ok, %{app: app, client_secret: secret}} = register("EXP", "x", "read")

      assert {:ok, t} = OAuth.client_credentials_grant(app.client_id, secret, "read")
      assert is_integer(t.expires_in) and t.expires_in > 0
      assert {:ok, _} = OAuth.verify_bearer(t.access_token)

      tok = SukhiFedi.AccountRepo.get_by!(OauthAccessToken, app_id: app.id)
      refute is_nil(tok.expires_at)

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      {:ok, _} = tok |> Ecto.Changeset.change(expires_at: past) |> SukhiFedi.AccountRepo.update()

      assert {:error, :expired} = OAuth.verify_bearer(t.access_token)
    end
  end

  describe "PKCE (a client with no secret)" do
    @redirect "https://gov.example/"
    @verifier String.duplicate("a1B2c3D4e5", 5)

    defp challenge(v), do: :crypto.hash(:sha256, v) |> Base.url_encode64(padding: false)

    defp ask(app, account, extra \\ %{}) do
      OAuth.create_authorization_code(
        app,
        account,
        Map.merge(%{redirect_uri: @redirect, scopes: "read"}, extra)
      )
    end

    defp pkce(app, code, verifier) do
      OAuth.exchange_code_for_token(%{
        "client_id" => app.client_id,
        "code" => code,
        "redirect_uri" => @redirect,
        "code_verifier" => verifier
      })
    end

    test "the verifier alone (no secret) turns the code into a token" do
      {:ok, %{app: app}} = register("Pkce1", @redirect)
      account = create_account!("u_pkce1")

      {:ok, %{code: code}} =
        ask(app, account, %{code_challenge: challenge(@verifier), code_challenge_method: "S256"})

      assert {:ok, %{access_token: t}} = pkce(app, code, @verifier)
      assert is_binary(t)
    end

    test "a wrong verifier is refused, and the code is spent" do
      {:ok, %{app: app}} = register("Pkce2", @redirect)
      account = create_account!("u_pkce2")

      {:ok, %{code: code}} =
        ask(app, account, %{code_challenge: challenge(@verifier), code_challenge_method: "S256"})

      assert {:error, :invalid_grant} = pkce(app, code, String.duplicate("z", 43))
      assert {:error, :invalid_grant} = pkce(app, code, @verifier)
    end

    test "no verifier for a code that has a challenge is refused" do
      {:ok, %{app: app}} = register("Pkce3", @redirect)
      account = create_account!("u_pkce3")

      {:ok, %{code: code}} =
        ask(app, account, %{code_challenge: challenge(@verifier), code_challenge_method: "S256"})

      assert {:error, :invalid_grant} = pkce(app, code, nil)
    end

    test "a code without a challenge still needs the secret; a verifier cannot stand in" do
      {:ok, %{app: app, client_secret: secret}} = register("Pkce4", @redirect)
      account = create_account!("u_pkce4")
      {:ok, %{code: code}} = ask(app, account)

      assert {:error, :invalid_client} = pkce(app, code, nil)
      assert {:error, :invalid_grant} = pkce(app, code, @verifier)

      assert {:ok, _} =
               OAuth.exchange_code_for_token(%{
                 "client_id" => app.client_id,
                 "client_secret" => secret,
                 "code" => code,
                 "redirect_uri" => @redirect
               })
    end

    test "only S256, well-formed challenges are accepted" do
      {:ok, %{app: app}} = register("Pkce5", @redirect)
      account = create_account!("u_pkce5")

      for extra <- [
            %{code_challenge: @verifier, code_challenge_method: "plain"},
            %{code_challenge: challenge(@verifier)},
            %{code_challenge: "short", code_challenge_method: "S256"},
            %{code_challenge_method: "S256"}
          ] do
        assert {:error, :invalid_request} = ask(app, account, extra)
      end
    end
  end

  describe "admin scope" do
    @redirect "https://gov.example/"

    defp admin!(username),
      do: insert_account!(%Account{username: username, display_name: username, summary: "t", is_admin: true})

    defp admin_app(owner_id) do
      OAuth.register_app(%{
        "client_name" => "gov",
        "redirect_uris" => @redirect,
        "scopes" => "admin:read admin:write",
        owner_account_id: owner_id
      })
    end

    defp want_admin(app, account),
      do: OAuth.create_authorization_code(app, account, %{redirect_uri: @redirect, scopes: "admin:read admin:write"})

    test "an admin, through an app an admin owns, gets the code" do
      owner = admin!("adm_owner")
      {:ok, %{app: app}} = admin_app(owner.id)
      assert {:ok, %{code: _}} = want_admin(app, admin!("adm_who"))
    end

    test "an account that is not an admin does not" do
      owner = admin!("adm_owner2")
      {:ok, %{app: app}} = admin_app(owner.id)
      # 人に「権限がありません」と言える理由(app の持ち主の誤りの :invalid_scope とは分ける)
      assert {:error, :admin_required} = want_admin(app, create_account!("not_admin"))
    end

    test "an app nobody (or a non-admin) owns does not, even for an admin" do
      {:ok, %{app: unowned}} = admin_app(nil)
      {:ok, %{app: by_user}} = admin_app(create_account!("plain_owner").id)
      who = admin!("adm_who2")
      assert {:error, :invalid_scope} = want_admin(unowned, who)
      assert {:error, :invalid_scope} = want_admin(by_user, who)
    end
  end

  defp register(name, redirect \\ "urn:ietf:wg:oauth:2.0:oob", scopes \\ "read") do
    OAuth.register_app(%{
      "client_name" => name,
      "redirect_uris" => redirect,
      "scopes" => scopes
    })
  end

  defp create_account!(username) do
    %Account{
      username: username,
      display_name: username,
      summary: "test"
    }
    |> insert_account!()
  end
end
