# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Auth.SecondFactor do
  @moduledoc """
  The one place that says whether a first factor (password or email
  code) is enough to mint a session, and that carries the login across
  the gap to the TOTP prompt.

  The gap is bridged by a *pending token*: `Plug.Crypto.sign` over the
  account id, 5 minutes of life, no DB row. It proves "this browser
  just passed a first factor for account N" and nothing else — a
  session still requires the TOTP code on top.

  Passkey login never comes through here: user verification on the
  authenticator is its own second factor.
  """

  import Ecto.Query

  alias SukhiFedi.Accounts
  alias SukhiFedi.Auth.TOTP
  alias SukhiFedi.AccountRepo
  alias SukhiFedi.Schema.Account

  @pending_salt "sukhi auth second factor"
  @pending_max_age 300

  @doc "Does a session for this account need a second factor?"
  @spec required?(Account.t()) :: boolean()
  def required?(%Account{totp_enabled_at: %DateTime{}}), do: true
  def required?(%Account{}), do: false

  @spec issue_pending(Account.t()) :: String.t()
  def issue_pending(%Account{id: id}),
    do: Plug.Crypto.sign(secret(), @pending_salt, id)

  @spec verify_pending(String.t()) :: {:ok, Account.t()} | {:error, :invalid_pending}
  def verify_pending(token) when is_binary(token) do
    with {:ok, id} <- Plug.Crypto.verify(secret(), @pending_salt, token, max_age: @pending_max_age),
         %Account{} = account <- Accounts.get(id) do
      {:ok, account}
    else
      _ -> {:error, :invalid_pending}
    end
  end

  def verify_pending(_), do: {:error, :invalid_pending}

  @doc """
  Check a TOTP code for the account and advance the replay high-water
  mark in the same breath. The UPDATE's WHERE clause is the atomic
  part: two concurrent submissions of the same code race into it and
  exactly one wins.
  """
  @spec verify_totp(Account.t(), String.t()) :: :ok | {:error, :invalid_code}
  def verify_totp(%Account{id: id, totp_secret: secret, totp_last_used_step: last}, code)
      when is_binary(secret) do
    case TOTP.valid?(secret, code, last) do
      {:ok, step} ->
        {n, _} =
          from(a in Account,
            where:
              a.id == ^id and
                (is_nil(a.totp_last_used_step) or a.totp_last_used_step < ^step)
          )
          |> AccountRepo.update_all(set: [totp_last_used_step: step])

        case n do
          1 -> :ok
          0 -> {:error, :invalid_code}
        end

      :error ->
        {:error, :invalid_code}
    end
  end

  def verify_totp(%Account{}, _code), do: {:error, :invalid_code}

  # ── TOTP lifecycle (settings surface) ────────────────────────────────────

  @doc """
  Park a fresh secret on the account (not yet counted as a factor) and
  hand back what the SPA needs to show: the otpauth URI for the QR and
  the base32 secret for manual entry. Re-running replaces an unproven
  secret; an enabled factor must be disabled first.
  """
  @spec setup_totp(Account.t()) ::
          {:ok, %{secret: String.t(), otpauth: String.t()}} | {:error, :already_enabled}
  def setup_totp(%Account{totp_enabled_at: %DateTime{}}), do: {:error, :already_enabled}

  def setup_totp(%Account{} = account) do
    secret = TOTP.generate_secret()

    {:ok, _} =
      account
      |> Ecto.Changeset.change(totp_secret: secret, totp_last_used_step: nil)
      |> AccountRepo.update()

    domain = Application.get_env(:sukhi_fedi, :domain, "localhost:4000")

    {:ok,
     %{
       secret: Base.encode32(secret, padding: false),
       otpauth: TOTP.otpauth_uri("#{account.username}@#{domain}", secret, domain)
     }}
  end

  @doc """
  The user proved they scanned the secret: the factor starts counting.
  Goes through `verify_totp/2`, so the proving code is burned for
  login replay too.
  """
  @spec enable_totp(Account.t(), String.t()) ::
          {:ok, Account.t()} | {:error, :invalid_code | :no_setup}
  def enable_totp(%Account{totp_secret: secret} = account, code) when is_binary(secret) do
    with :ok <- verify_totp(account, code) do
      account
      |> Ecto.Changeset.change(totp_enabled_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> AccountRepo.update()
    end
  end

  def enable_totp(%Account{}, _code), do: {:error, :no_setup}

  @spec disable_totp(Account.t()) :: {:ok, Account.t()}
  def disable_totp(%Account{} = account) do
    account
    |> Ecto.Changeset.change(totp_secret: nil, totp_enabled_at: nil, totp_last_used_step: nil)
    |> AccountRepo.update()
  end

  defp secret, do: Application.fetch_env!(:sukhi_fedi, :secret_key_base)
end
