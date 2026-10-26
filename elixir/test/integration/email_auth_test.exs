# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.EmailAuthTest do
  @moduledoc """
  Email verification + email-code login, end to end against the test
  Postgres, with mails captured by `SukhiFedi.Mailer.Capture`.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Auth.EmailAuth
  alias SukhiFedi.{LocalAccounts, Mailer}
  alias SukhiFedi.Schema.EmailCode

  setup do
    Mailer.Capture.clear()

    n = System.unique_integer([:positive])
    {:ok, account} = LocalAccounts.create_admin("mailauth_#{n}", "long-enough-pass")
    %{account: account, email: "mailauth_#{n}@example.test"}
  end

  defp code_from_mail(to) do
    %{body: body} = Mailer.Capture.last_to(to)
    [_, code] = Regex.run(~r/\n\s+(\d{6})\n/, body)
    code
  end

  describe "verification" do
    test "request → confirm lands the verified address", %{account: account, email: email} do
      assert :ok = EmailAuth.request_verification(account, email)
      assert {:ok, updated} = EmailAuth.confirm_verification(account, code_from_mail(email))

      assert updated.email == email
      assert %DateTime{} = updated.email_verified_at
    end

    test "changing a verified address mails the old one once", %{account: account, email: email} do
      assert :ok = EmailAuth.request_verification(account, email)
      assert {:ok, verified} = EmailAuth.confirm_verification(account, code_from_mail(email))
      refute Mailer.Capture.last_to(email) |> Map.fetch!(:subject) =~ "変更"

      Mailer.Capture.clear()
      new_email = "new_" <> email

      # Swapping a verified address needs the account as it now stands.
      assert :ok = EmailAuth.request_verification(verified, new_email)
      assert {:ok, _} = EmailAuth.confirm_verification(verified, code_from_mail(new_email))

      assert %{subject: subject, body: body} = Mailer.Capture.last_to(email)
      assert subject =~ "変更"
      assert body =~ "ne***@"
      refute body =~ new_email
    end

    test "first-time verification mails nobody else", %{account: account, email: email} do
      assert :ok = EmailAuth.request_verification(account, email)
      code = code_from_mail(email)
      Mailer.Capture.clear()
      assert {:ok, _} = EmailAuth.confirm_verification(account, code)
      assert Mailer.Capture.last_to(email) == nil
    end

    test "normalizes case and refuses junk addresses", %{account: account, email: email} do
      assert :ok = EmailAuth.request_verification(account, "  " <> String.upcase(email) <> " ")
      assert {:ok, updated} = EmailAuth.confirm_verification(account, code_from_mail(email))
      assert updated.email == email

      assert {:error, :invalid_email} = EmailAuth.request_verification(account, "not-an-email")
      assert {:error, :invalid_email} = EmailAuth.request_verification(account, "a b@c.d")
    end

    test "an address verified by someone else is taken", %{account: account, email: email} do
      assert :ok = EmailAuth.request_verification(account, email)
      assert {:ok, _} = EmailAuth.confirm_verification(account, code_from_mail(email))

      {:ok, other} =
        LocalAccounts.create_admin("mailauth_o_#{System.unique_integer([:positive])}", "long-enough-pass")

      assert {:error, :email_taken} = EmailAuth.request_verification(other, email)
    end

    test "five wrong guesses burn the code", %{account: account, email: email} do
      assert :ok = EmailAuth.request_verification(account, email)
      real = code_from_mail(email)
      wrong = if real == "000000", do: "000001", else: "000000"

      for _ <- 1..5 do
        assert {:error, :invalid_code} = EmailAuth.confirm_verification(account, wrong)
      end

      # The right code no longer works either — request a fresh one.
      assert {:error, :too_many_attempts} = EmailAuth.confirm_verification(account, real)
    end

    test "an expired code says so", %{account: account, email: email} do
      assert :ok = EmailAuth.request_verification(account, email)

      import Ecto.Query
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      {1, _} =
        from(c in EmailCode, where: c.account_id == ^account.id)
        |> Repo.update_all(set: [expires_at: past])

      assert {:error, :expired} = EmailAuth.confirm_verification(account, code_from_mail(email))
    end

    test "re-requesting replaces the previous code", %{account: account, email: email} do
      assert :ok = EmailAuth.request_verification(account, email)
      first = code_from_mail(email)
      assert :ok = EmailAuth.request_verification(account, email)
      second = code_from_mail(email)

      if first != second do
        assert {:error, :invalid_code} = EmailAuth.confirm_verification(account, first)
      end

      assert {:ok, _} = EmailAuth.confirm_verification(account, second)
    end

    test "sends are rate-limited per address", %{account: account} do
      email = "ratelimit_#{System.unique_integer([:positive])}@example.test"

      for _ <- 1..3, do: assert(:ok = EmailAuth.request_verification(account, email))
      assert {:error, :rate_limited} = EmailAuth.request_verification(account, email)
    end
  end

  describe "email login" do
    setup %{account: account, email: email} do
      :ok = EmailAuth.request_verification(account, email)
      {:ok, account} = EmailAuth.confirm_verification(account, code_from_mail(email))
      %{account: account}
    end

    test "request → confirm returns the account", %{account: account, email: email} do
      assert :ok = EmailAuth.request_login_code(email)
      assert {:ok, found} = EmailAuth.confirm_login(email, code_from_mail(email))
      assert found.id == account.id
    end

    test "an unverified or unknown address gets :ok and no mail" do
      ghost = "nobody_#{System.unique_integer([:positive])}@example.test"
      assert :ok = EmailAuth.request_login_code(ghost)
      assert is_nil(Mailer.Capture.last_to(ghost))

      {:ok, plain} =
        LocalAccounts.create_admin(
          "mailauth_u_#{System.unique_integer([:positive])}",
          "long-enough-pass",
          email: "unverified_#{System.unique_integer([:positive])}@example.test"
        )

      assert :ok = EmailAuth.request_login_code(plain.email)
      assert is_nil(Mailer.Capture.last_to(plain.email))
    end

    test "a wrong code is just invalid", %{email: email} do
      assert :ok = EmailAuth.request_login_code(email)
      real = code_from_mail(email)
      wrong = if real == "000000", do: "000001", else: "000000"

      assert {:error, :invalid_code} = EmailAuth.confirm_login(email, wrong)
      # the real one still has attempts left
      assert {:ok, _} = EmailAuth.confirm_login(email, real)
      # ...and is single-use
      assert {:error, :invalid_code} = EmailAuth.confirm_login(email, real)
    end
  end

  describe "signup codes (no account yet)" do
    test "request → confirm yields a proof of the normalized address" do
      email = "presign_#{System.unique_integer([:positive])}@example.test"

      assert :ok = EmailAuth.request_signup_code("  " <> String.upcase(email) <> " ")
      assert {:ok, proof} = EmailAuth.confirm_signup_code(email, code_from_mail(email))
      assert {:ok, ^email} = EmailAuth.verify_signup_proof(proof)
    end

    test "garbage proofs verify to nothing" do
      assert {:error, :invalid_proof} = EmailAuth.verify_signup_proof("garbage")
      assert {:error, :invalid_proof} = EmailAuth.verify_signup_proof(nil)
    end

    test "an address with a verified owner is refused", %{account: account, email: email} do
      :ok = EmailAuth.request_verification(account, email)
      {:ok, _} = EmailAuth.confirm_verification(account, code_from_mail(email))

      assert {:error, :email_taken} = EmailAuth.request_signup_code(email)
    end

    test "a wrong signup code burns attempts like the others" do
      email = "presign_w_#{System.unique_integer([:positive])}@example.test"
      assert :ok = EmailAuth.request_signup_code(email)
      real = code_from_mail(email)
      wrong = if real == "000000", do: "000001", else: "000000"

      assert {:error, :invalid_code} = EmailAuth.confirm_signup_code(email, wrong)
      assert {:ok, _} = EmailAuth.confirm_signup_code(email, real)
      # one-shot row
      assert {:error, :invalid_code} = EmailAuth.confirm_signup_code(email, real)
    end
  end

  describe "reauth codes" do
    test "only a verified address can receive one", %{account: account} do
      assert {:error, :no_verified_email} = EmailAuth.request_reauth(account)
    end

    test "request → confirm, single-use", %{account: account, email: email} do
      :ok = EmailAuth.request_verification(account, email)
      {:ok, account} = EmailAuth.confirm_verification(account, code_from_mail(email))

      assert :ok = EmailAuth.request_reauth(account)
      code = code_from_mail(email)

      assert :ok = EmailAuth.confirm_reauth(account, code)
      assert {:error, :invalid_code} = EmailAuth.confirm_reauth(account, code)
    end
  end
end
