# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.LocalAccountsTest do
  @moduledoc """
  Admin bootstrap + password change. Requires the test Postgres:

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  import Ecto.Query, only: [from: 2]

  @moduletag :integration

  alias SukhiFedi.{Accounts, LocalAccounts}

  describe "create_admin/3" do
    test "mints a local admin account that can authenticate" do
      name = "admin_#{System.unique_integer([:positive])}"

      assert {:ok, account} = LocalAccounts.create_admin(name, "long-enough-pass")
      assert account.is_admin
      assert is_nil(account.domain)
      assert is_binary(account.password_hash)

      assert {:ok, signed_in} = LocalAccounts.authenticate(name, "long-enough-pass")
      assert signed_in.id == account.id
    end

    test "rejects a password under the 8-byte floor" do
      name = "admin_#{System.unique_integer([:positive])}"
      assert {:error, :password_too_short} = LocalAccounts.create_admin(name, "short")
    end

    test "rejects a duplicate username" do
      name = "admin_#{System.unique_integer([:positive])}"
      assert {:ok, _} = LocalAccounts.create_admin(name, "long-enough-pass")
      assert {:error, {:validation, errors}} = LocalAccounts.create_admin(name, "long-enough-pass")
      assert Map.has_key?(errors, :username)
    end
  end

  describe "create/1 (signup)" do
    setup do
      SukhiFedi.Mailer.Capture.clear()
      issuer = "inv_#{System.unique_integer([:positive])}"
      {:ok, issuer} = LocalAccounts.create_admin(issuer, "long-enough-pass")
      {:ok, invite} = SukhiFedi.InviteCodes.issue(issuer.id)
      %{invite: invite.code, issuer: issuer}
    end

    defp proof_for(email) do
      :ok = SukhiFedi.Auth.EmailAuth.request_signup_code(email)
      %{body: body} = SukhiFedi.Mailer.Capture.last_to(email |> String.trim() |> String.downcase())
      [_, code] = Regex.run(~r/\n\s+(\d{6})\n/, body)
      {:ok, proof} = SukhiFedi.Auth.EmailAuth.confirm_signup_code(email, code)
      proof
    end

    defp signup_attrs(invite, overrides) do
      n = System.unique_integer([:positive])

      Map.merge(
        %{
          "username" => "signup_#{n}",
          "email_proof" => proof_for("signup_#{n}@example.test"),
          "invite_code" => invite
        },
        overrides
      )
    end


    # ── 招待してくれた人を、ひとつだけフォローする ────────────────────
    #
    # 繋がりのためでもあるけれど、本体は**招待した側への知らせ**。
    # コードを渡したあと、その人が来たのかどうか分かる道がこれまで無かった。
    # follow 通知なら、よその実装のアプリでもそのまま読める。

    defp follows?(follower, target_id) do
      uri = "https://#{SukhiFedi.Config.domain!()}/users/#{follower.username}"

      SukhiFedi.Repo.exists?(
        from f in SukhiFedi.Schema.Follow,
          where: f.follower_uri == ^uri and f.followee_id == ^target_id
      )
    end

    test "入った人は、招待してくれた人をフォローしている", %{invite: invite, issuer: issuer} do
      {:ok, newcomer} = LocalAccounts.create(signup_attrs(invite, %{}))
      assert follows?(newcomer, issuer.id)
    end

    test "**片方向だけ** — 招待した側は、勝手にフォローバックしない", %{invite: invite, issuer: issuer} do
      # 繋がるかどうかは、招待した人が選ぶこと。
      {:ok, newcomer} = LocalAccounts.create(signup_attrs(invite, %{}))
      refute follows?(issuer, newcomer.id)
    end

    test "代理で出された招待は、その「誰か」を向く", %{issuer: issuer} do
      on_behalf = "onbehalf_#{System.unique_integer([:positive])}"
      {:ok, friend} = LocalAccounts.create_admin(on_behalf, "long-enough-pass")
      {:ok, inv} = SukhiFedi.InviteCodes.issue(issuer.id, on_behalf_of_id: friend.id)

      {:ok, newcomer} = LocalAccounts.create(signup_attrs(inv.code, %{}))

      # 発行したのは管理者でも、繋がるべき相手は名前を貸した人のほう。
      assert follows?(newcomer, friend.id)
      refute follows?(newcomer, issuer.id)
    end

    test "フォローが作れなくても、登録そのものは通る", %{invite: invite, issuer: issuer} do
      # 招待した人が先に消えている、というような場合。フォロー一本のために
      # account を巻き戻すほうが重いので、登録は必ず生かす。
      SukhiFedi.Repo.delete!(issuer)
      assert {:ok, _newcomer} = LocalAccounts.create(signup_attrs(invite, %{}))
    end

    test "born passwordless with the proven address verified", %{invite: invite} do
      attrs = signup_attrs(invite, %{})

      assert {:ok, account} = LocalAccounts.create(attrs)
      assert account.email =~ "@example.test"
      assert %DateTime{} = account.email_verified_at
      assert is_nil(account.password_hash)

      # no password door…
      assert {:error, :invalid} = LocalAccounts.authenticate(account.username, "anything-here")
      # …but the email door is open from minute one
      assert %{id: id} = SukhiFedi.Auth.EmailAuth.login_account_by_email(account.email)
      assert id == account.id
    end

    test "the proof carries the normalized address", %{invite: invite} do
      email = "  Mixed.Case#{System.unique_integer([:positive])}@Example.TEST "
      attrs = signup_attrs(invite, %{"email_proof" => proof_for(email)})

      assert {:ok, account} = LocalAccounts.create(attrs)
      assert account.email == email |> String.trim() |> String.downcase()
    end

    test "a password may still be set at signup (legacy, optional)", %{invite: invite} do
      attrs = signup_attrs(invite, %{"password" => "long-enough-pass"})
      assert {:ok, account} = LocalAccounts.create(attrs)
      assert is_binary(account.password_hash)
      assert {:ok, _} = LocalAccounts.authenticate(account.username, "long-enough-pass")
    end

    test "a blank password means none, a short one is refused", %{invite: invite} do
      attrs = signup_attrs(invite, %{"password" => ""})
      assert {:ok, account} = LocalAccounts.create(attrs)
      assert is_nil(account.password_hash)

      issuer = "inv3_#{System.unique_integer([:positive])}"
      {:ok, issuer} = LocalAccounts.create_admin(issuer, "long-enough-pass")
      {:ok, invite2} = SukhiFedi.InviteCodes.issue(issuer.id)

      attrs = signup_attrs(invite2.code, %{"password" => "short"})
      assert {:error, :password_too_short} = LocalAccounts.create(attrs)
    end

    test "a missing or garbled proof is refused", %{invite: invite} do
      attrs = %{
        "username" => "noproof_#{System.unique_integer([:positive])}",
        "invite_code" => invite
      }

      assert {:error, :email_proof_invalid} = LocalAccounts.create(attrs)

      assert {:error, :email_proof_invalid} =
               LocalAccounts.create(Map.put(attrs, "email_proof", "garbage"))
    end

    # ── 招待コードを、必須ではなくする ────────────────────────────────
    #
    # natadeco のように、誰でも入れる場所のため。メールは残す ── アカウ
    # ントをなくしたとき、そこから帰ってこられるから。

    defp without_invite(fun) do
      Application.put_env(:sukhi_fedi, :invite_required, false)
      try do
        fun.()
      after
        Application.delete_env(:sukhi_fedi, :invite_required)
      end
    end

    test "門が開いているなら、コード無しで入れる" do
      without_invite(fn ->
        n = System.unique_integer([:positive])

        attrs = %{
          "username" => "open_#{n}",
          "email_proof" => proof_for("open_#{n}@example.test")
        }

        assert {:ok, account} = LocalAccounts.create(attrs)
        assert is_nil(account.domain)
        assert %DateTime{} = account.email_verified_at
      end)
    end

    test "門が開いていても、メールは要る" do
      without_invite(fn ->
        n = System.unique_integer([:positive])
        assert {:error, :email_proof_invalid} = LocalAccounts.create(%{"username" => "noml_#{n}"})
      end)
    end

    test "門が開いていても、渡されたコードはちゃんと使われる", %{invite: invite, issuer: issuer} do
      without_invite(fn ->
        {:ok, newcomer} = LocalAccounts.create(signup_attrs(invite, %{}))
        # 招待した人には、来たことが伝わってほしい。
        assert follows?(newcomer, issuer.id)
        # 一度きりのコードは、開いていても一度きり。
        assert {:error, :invite_used} = LocalAccounts.create(signup_attrs(invite, %{}))
      end)
    end

    test "門が閉じているなら、コード無しは断る" do
      n = System.unique_integer([:positive])

      assert {:error, :invite_missing} =
               LocalAccounts.create(%{
                 "username" => "closed_#{n}",
                 "email_proof" => proof_for("closed_#{n}@example.test")
               })
    end

    test "a verified address cannot be claimed twice", %{invite: invite} do
      email = "claimed_#{System.unique_integer([:positive])}@example.test"
      # two proofs up front — the second simulates a stale-but-valid one
      proof1 = proof_for(email)
      proof2 = proof_for(email)

      assert {:ok, _} = LocalAccounts.create(signup_attrs(invite, %{"email_proof" => proof1}))

      # a fresh code request now says taken…
      assert {:error, :email_taken} = SukhiFedi.Auth.EmailAuth.request_signup_code(email)

      # …and replaying the stale proof trips the unique index
      issuer = "inv2_#{System.unique_integer([:positive])}"
      {:ok, issuer} = LocalAccounts.create_admin(issuer, "long-enough-pass")
      {:ok, invite2} = SukhiFedi.InviteCodes.issue(issuer.id)

      assert {:error, {:validation, %{email: _}}} =
               LocalAccounts.create(signup_attrs(invite2.code, %{"email_proof" => proof2}))
    end
  end

  describe "set_initial_password/2 and remove_password/1" do
    setup do
      SukhiFedi.Mailer.Capture.clear()
      issuer = "inv_#{System.unique_integer([:positive])}"
      {:ok, issuer} = LocalAccounts.create_admin(issuer, "long-enough-pass")
      {:ok, invite} = SukhiFedi.InviteCodes.issue(issuer.id)
      {:ok, account} = LocalAccounts.create(signup_attrs(invite.code, %{}))
      %{account: account}
    end

    test "a passwordless account can gain a password, once", %{account: account} do
      assert {:error, :password_too_short} = LocalAccounts.set_initial_password(account, "short")
      assert {:ok, with_pw} = LocalAccounts.set_initial_password(account, "first-password")
      assert {:ok, _} = LocalAccounts.authenticate(account.username, "first-password")

      # with a hash in place, the no-questions-asked door closes
      assert {:error, :has_password} =
               LocalAccounts.set_initial_password(with_pw, "other-password")
    end

    test "removing the password keeps the email door open", %{account: account} do
      {:ok, with_pw} = LocalAccounts.set_initial_password(account, "first-password")

      assert {:ok, without} = LocalAccounts.remove_password(with_pw)
      assert is_nil(without.password_hash)
      assert {:error, :invalid} = LocalAccounts.authenticate(account.username, "first-password")
      assert %{} = SukhiFedi.Auth.EmailAuth.login_account_by_email(account.email)
    end

    test "an account without a verified email cannot drop its password" do
      name = "noemail_#{System.unique_integer([:positive])}"
      {:ok, admin} = LocalAccounts.create_admin(name, "long-enough-pass")
      assert {:error, :no_verified_email} = LocalAccounts.remove_password(admin)
    end
  end

  describe "change_password/3" do
    setup do
      name = "user_#{System.unique_integer([:positive])}"
      {:ok, account} = LocalAccounts.create_admin(name, "original-pass")
      %{account: account, name: name}
    end

    test "swaps the password when the current one matches", %{account: account, name: name} do
      assert {:ok, _} = LocalAccounts.change_password(account, "original-pass", "brand-new-pass")

      assert {:error, :invalid} = LocalAccounts.authenticate(name, "original-pass")
      assert {:ok, _} = LocalAccounts.authenticate(name, "brand-new-pass")
    end

    test "revokes the account's OAuth tokens too (C5)", %{account: account} do
      # Insert the app row directly (no register_app side effects) — we only
      # need a valid app_id FK for the token.
      app =
        SukhiFedi.Repo.insert!(%SukhiFedi.Schema.OauthApp{
          client_id: "c_#{System.unique_integer([:positive])}",
          client_secret_hash: "x",
          name: "pwchg",
          redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
          scopes: "read"
        })

      {:ok, tok} =
        %SukhiFedi.Schema.OauthAccessToken{}
        |> SukhiFedi.Schema.OauthAccessToken.changeset(%{
          token_hash: "th_#{System.unique_integer([:positive])}",
          scopes: "read",
          app_id: app.id,
          account_id: account.id
        })
        |> SukhiFedi.Repo.insert()

      assert is_nil(tok.revoked_at)

      assert {:ok, _} = LocalAccounts.change_password(account, "original-pass", "brand-new-pass")

      assert SukhiFedi.Repo.get(SukhiFedi.Schema.OauthAccessToken, tok.id).revoked_at != nil
    end

    test "rejects a wrong current password", %{account: account, name: name} do
      assert {:error, :invalid_current} =
               LocalAccounts.change_password(account, "wrong-pass", "brand-new-pass")

      # unchanged — the original still works
      assert {:ok, _} = LocalAccounts.authenticate(name, "original-pass")
    end

    test "enforces the 8-byte floor on the new password", %{account: account} do
      assert {:error, :password_too_short} =
               LocalAccounts.change_password(account, "original-pass", "short")
    end

    test "revokes every session on success", %{account: account} do
      {:ok, token} = LocalAccounts.create_session(account)
      assert %{id: id} = Accounts.get_account_by_session_token(token)
      assert id == account.id

      assert {:ok, _} = LocalAccounts.change_password(account, "original-pass", "brand-new-pass")

      # the old session no longer resolves to an account
      assert is_nil(Accounts.get_account_by_session_token(token))
    end

    test "leaves sessions intact when the current password is wrong", %{account: account} do
      {:ok, token} = LocalAccounts.create_session(account)

      assert {:error, :invalid_current} =
               LocalAccounts.change_password(account, "wrong-pass", "brand-new-pass")

      assert %{id: id} = Accounts.get_account_by_session_token(token)
      assert id == account.id
    end
  end
end
