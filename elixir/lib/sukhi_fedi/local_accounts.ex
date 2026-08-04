# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.LocalAccounts do
  @moduledoc """
  Create local accounts (the `domain IS NULL` rows). Reachable from
  the api node as `SukhiApi.GatewayRpc.call(SukhiFedi.LocalAccounts,
  :create, [attrs])` from the `POST /api/v1/accounts` capability.

  The signup transaction:

    1. consume the invite code
    2. mint an Ed25519/RSA keypair (the AP actor's own keys)
    3. insert the account row with `domain: nil` and `password_hash`

  If any step fails the whole transaction rolls back, so a failed
  insert won't leave a half-spent invite. Keypair generation uses the
  same `NodeinfoMonitor.KeyGen` helper that seeds bot actors, since
  the shape (`%{public_pem, public_jwk, private_jwk}`) matches what
  the AP actor controller already publishes.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias SukhiFedi.Addons.NodeinfoMonitor.KeyGen
  alias SukhiFedi.{InviteCodes, Repo}
  alias SukhiFedi.Schema.{Account, Session}

  require Logger

  @type signup_attrs :: %{
          required(:username) => String.t(),
          # Signed proof from `EmailAuth.confirm_signup_code/2` — the
          # mailbox is proven *before* the account exists, so the row
          # is born with `email_verified_at` set and email login works
          # from minute one. That is also what makes the password safe
          # to skip: a passwordless account always has a working door.
          required(:email_proof) => String.t(),
          optional(:password) => String.t() | nil,
          optional(:display_name) => String.t() | nil,
          required(:invite_code) => String.t()
        }

  @spec create(signup_attrs() | map()) ::
          {:ok, Account.t()}
          | {:error, :invite_invalid}
          | {:error, :invite_used}
          | {:error, :invite_expired}
          | {:error, :invite_missing}
          | {:error, :email_proof_invalid}
          | {:error, :password_too_short}
          | {:error, {:validation, map()}}
  def create(attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize(attrs),
         {:ok, hash} <- maybe_hash_password(normalized.password),
         keys = KeyGen.generate() do
      account_attrs = %{
        username: normalized.username,
        display_name: normalized.display_name || normalized.username,
        email: normalized.email,
        password_hash: hash,
        public_key_pem: keys.public_pem,
        public_key_jwk: keys.public_jwk,
        private_key_jwk: keys.private_jwk,
        ed25519_private_key_jwk: keys.ed25519_private_jwk,
        ed25519_public_multibase: keys.ed25519_public_multibase
      }

      changeset =
        %Account{}
        |> Account.changeset_local(account_attrs)
        # put_change, not cast: the signed proof is the only road to a
        # verified-at-birth address.
        |> Ecto.Changeset.put_change(
          :email_verified_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )

      Multi.new()
      |> Multi.insert(:account, changeset)
      |> Multi.run(:invite, fn _repo, %{account: %Account{id: id}} ->
        case InviteCodes.consume(normalized.invite_code, id) do
          {:ok, ic} -> {:ok, ic}
          {:error, :invalid} -> {:error, :invite_invalid}
          {:error, :already_used} -> {:error, :invite_used}
          {:error, :expired} -> {:error, :invite_expired}
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{account: a, invite: invite}} ->
          follow_inviter(a, invite)
          {:ok, a}

        {:error, :account, %Ecto.Changeset{} = cs, _} -> {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
        {:error, :invite, reason, _} -> {:error, reason}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
  Create a local account with `is_admin: true`, bypassing the
  invite-code requirement.

  This is the bootstrap door for the very first operator: signup needs
  an invite, and `Accounts.set_admin/3` needs an existing admin to drive
  the back-office UI, so neither can mint the first admin. Reachable as a
  release task — see `SukhiFedi.Release.create_admin/3`.

  `is_admin` is forced on with `put_change`, not cast, so an ordinary
  signup can never smuggle it in through `changeset_local`.
  """
  @spec create_admin(String.t(), String.t(), keyword()) ::
          {:ok, Account.t()}
          | {:error, :password_too_short}
          | {:error, {:validation, map()}}
  def create_admin(username, password, opts \\ [])
      when is_binary(username) and is_binary(password) do
    username = username |> String.trim() |> String.downcase()
    display_name = Keyword.get(opts, :display_name) || username

    with {:ok, hash} <- hash_password(password) do
      keys = KeyGen.generate()

      attrs = %{
        username: username,
        display_name: display_name,
        email: Keyword.get(opts, :email),
        password_hash: hash,
        public_key_pem: keys.public_pem,
        public_key_jwk: keys.public_jwk,
        private_key_jwk: keys.private_jwk,
        ed25519_private_key_jwk: keys.ed25519_private_jwk,
        ed25519_public_multibase: keys.ed25519_public_multibase
      }

      %Account{}
      |> Account.changeset_local(attrs)
      |> Ecto.Changeset.put_change(:is_admin, true)
      |> Repo.insert()
      |> case do
        {:ok, a} -> {:ok, a}
        {:error, cs} -> {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
      end
    end
  end

  defp normalize(attrs) do
    get = fn keys ->
      Enum.find_value(keys, fn k -> Map.get(attrs, k) end)
    end

    username = get.(["username", :username]) |> trim_or_nil()
    password = get.(["password", :password])
    invite = get.(["invite_code", :invite_code, "token", :token]) |> trim_or_nil()
    proof = get.(["email_proof", :email_proof])
    display_name = get.(["display_name", :display_name]) |> trim_or_nil()

    # The email arrives as a signed proof (mailbox already opened),
    # never as a raw address — required regardless of whether a
    # password is set. The password itself is optional/legacy.
    cond do
      is_nil(invite) ->
        {:error, :invite_missing}

      is_nil(username) ->
        {:error, {:validation, %{username: ["を入れてください"]}}}

      true ->
        case SukhiFedi.Auth.EmailAuth.verify_signup_proof(proof) do
          {:ok, email} ->
            {:ok,
             %{
               username: String.downcase(username),
               password: password,
               invite_code: invite,
               email: email,
               display_name: display_name
             }}

          {:error, :invalid_proof} ->
            {:error, :email_proof_invalid}
        end
    end
  end

  defp trim_or_nil(nil), do: nil
  defp trim_or_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end

  defp hash_password(p) when is_binary(p) and byte_size(p) >= 8 do
    {:ok, Argon2.hash_pwd_salt(p)}
  end

  defp hash_password(_), do: {:error, :password_too_short}

  # Signup-side: no password at all is fine (passwordless account);
  # a present one must still clear the 8-byte floor.
  defp maybe_hash_password(nil), do: {:ok, nil}
  defp maybe_hash_password(""), do: {:ok, nil}
  defp maybe_hash_password(p), do: hash_password(p)

  @doc """
  Verify a username + password against a local account, returning the
  account on match. Used by the `/login` controller before minting a
  session cookie.
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, Account.t()} | {:error, :invalid}
  def authenticate(username, password) when is_binary(username) and is_binary(password) do
    case SukhiFedi.Accounts.by_local_username(String.downcase(username)) do
      %Account{password_hash: hash} = a when is_binary(hash) ->
        if Argon2.verify_pass(password, hash), do: {:ok, a}, else: {:error, :invalid}

      _ ->
        # Run the verifier anyway to keep the timing close to a real hit.
        Argon2.no_user_verify()
        {:error, :invalid}
    end
  end

  def authenticate(_, _), do: {:error, :invalid}

  @doc """
  Verify a password against the account's stored hash, with the dummy
  verify on the miss path so timing stays flat. The single "are you
  really you?" gate for factor-removing settings (TOTP off, passkey
  delete, changing a verified email) — and the inner check of
  `change_password/3`.
  """
  @spec check_password(Account.t(), term()) :: :ok | {:error, :invalid}
  def check_password(%Account{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password) do
    if Argon2.verify_pass(password, hash), do: :ok, else: {:error, :invalid}
  end

  def check_password(_, _) do
    Argon2.no_user_verify()
    {:error, :invalid}
  end

  @doc """
  Change a local account's password.

  Verifies `current` against the stored hash before swapping in a hash
  of `new`. Returns `{:error, :invalid_current}` if the current password
  doesn't match (with a dummy verify to keep timing even on the account
  that has no hash, e.g. a remote row), or `{:error, :password_too_short}`
  if `new` is under 8 bytes — same floor as signup.

  On success every session for the account is revoked in the same
  transaction, so a changed password logs out all devices (including the
  one that made the change) — they have to sign in again with the new
  password.
  """
  @spec change_password(Account.t(), String.t(), String.t()) ::
          {:ok, Account.t()}
          | {:error, :invalid_current}
          | {:error, :password_too_short}
  def change_password(%Account{id: id} = account, current, new)
      when is_binary(current) and is_binary(new) do
    with :ok <- check_password(account, current),
         {:ok, new_hash} <- hash_password(new) do
      Multi.new()
      |> Multi.update(:account, Ecto.Changeset.change(account, %{password_hash: new_hash}))
      |> Multi.delete_all(:sessions, from(s in Session, where: s.account_id == ^id))
      # Also revoke the account's OAuth bearer tokens, so "change
      # password" actually logs out every API client/device — not just
      # cookie sessions. Otherwise a leaked, never-expiring token kept
      # working after a password change.
      |> Multi.update_all(
        :tokens,
        from(t in SukhiFedi.Schema.OauthAccessToken,
          where: t.account_id == ^id and is_nil(t.revoked_at)
        ),
        set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{account: a}} -> {:ok, a}
        {:error, _step, reason, _} -> {:error, reason}
      end
    else
      {:error, :invalid} -> {:error, :invalid_current}
      {:error, :password_too_short} -> {:error, :password_too_short}
    end
  end

  @doc """
  Give a passwordless account its first password. No "current" check —
  there is nothing to check against — but only when the hash really is
  absent: an account *with* a password must go through
  `change_password/3` and prove the old one.

  Adding a factor doesn't lock anyone out (email login keeps working),
  so no session revocation here.
  """
  @spec set_initial_password(Account.t(), String.t()) ::
          {:ok, Account.t()} | {:error, :has_password | :password_too_short}
  def set_initial_password(%Account{password_hash: nil} = account, new) when is_binary(new) do
    with {:ok, hash} <- hash_password(new) do
      account
      |> Ecto.Changeset.change(%{password_hash: hash})
      |> Repo.update()
    end
  end

  def set_initial_password(%Account{}, _new), do: {:error, :has_password}

  @doc """
  Retire the account's password — the "legacy off" switch. Refused
  while the email is unverified: with no password *and* no email door,
  only a passkey (or nobody) could ever get back in. The caller gates
  this behind a fresh re-auth (`SecurityController`); existing
  sessions stay valid — removing a factor compromises nothing they
  hold.
  """
  @spec remove_password(Account.t()) :: {:ok, Account.t()} | {:error, :no_verified_email}
  def remove_password(%Account{email_verified_at: %DateTime{}} = account) do
    # Only the password goes. TOTP stays — it seconds the email door
    # just as it seconded the password one.
    account
    |> Ecto.Changeset.change(%{password_hash: nil})
    |> Repo.update()
  end

  def remove_password(%Account{}), do: {:error, :no_verified_email}

  @session_ttl_days 30

  @typedoc """
  The device behind a login, as resolved from the request at the cookie
  chokepoint (`Web.Auth.SessionCookie.mint/2`). Both fields may be nil
  — a mint outside a request has no fingerprint.
  """
  @type session_context :: %{
          optional(:ip_text) => String.t() | nil,
          optional(:user_agent) => String.t() | nil
        }

  @doc """
  Mint a session row for `account` and return the plaintext token. The
  token is base64url-encoded random bytes; only the SHA-256 hash is
  persisted (same pattern as OAuth access tokens). The caller drops
  the plaintext into a `session_token` cookie.

  The optional `context` carries the device fingerprint (coarse IP +
  user-agent). When it names a device this account has *never* signed
  in from before (`new_device?/2`), a single quiet "a new device signed
  in" mail goes out — a heads-up after the fact, never a gate: the
  session is minted regardless, and the real second factor (TOTP /
  passkey) has already done its job upstream.
  """
  @spec create_session(Account.t() | integer(), session_context()) :: {:ok, String.t()}
  def create_session(account, context \\ %{})

  def create_session(%Account{id: id}, context), do: create_session(id, context)

  def create_session(account_id, context) when is_integer(account_id) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, @session_ttl_days * 24 * 60 * 60, :second)

    ip = context[:ip_text]
    ua = context[:user_agent]

    # Read the prior fingerprints *before* inserting this one, so the
    # device that's signing in now never counts itself as "seen".
    new_device? = new_device?({ip, ua}, prior_fingerprints(account_id))

    {:ok, _} =
      %SukhiFedi.Schema.Session{}
      |> Ecto.Changeset.cast(
        %{
          token_hash: hash,
          expires_at: expires_at,
          account_id: account_id,
          ip_text: ip,
          user_agent: ua,
          last_seen_at: now
        },
        [:token_hash, :expires_at, :account_id, :ip_text, :user_agent, :last_seen_at]
      )
      |> Repo.insert()

    if new_device?, do: notify_new_device(account_id, ip)

    {:ok, token}
  end

  @doc """
  Every live (unexpired) session for `account`, newest first — what the
  security page lists so the owner can see where they're signed in.
  """
  @spec list_sessions(Account.t() | integer()) :: [Session.t()]
  def list_sessions(%Account{id: id}), do: list_sessions(id)

  def list_sessions(account_id) when is_integer(account_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(s in Session,
      where: s.account_id == ^account_id and s.expires_at > ^now,
      order_by: [desc: s.created_at]
    )
    |> Repo.all()
  end

  @doc """
  Revoke one of `account`'s own sessions by id. Scoped to the account,
  so the id alone can't reach across owners. `{:error, :not_found}` when
  no such row belongs to this account.
  """
  @spec revoke_session(Account.t() | integer(), integer()) :: :ok | {:error, :not_found}
  def revoke_session(%Account{id: id}, session_id), do: revoke_session(id, session_id)

  def revoke_session(account_id, session_id)
      when is_integer(account_id) and is_integer(session_id) do
    {count, _} =
      from(s in Session, where: s.id == ^session_id and s.account_id == ^account_id)
      |> Repo.delete_all()

    if count == 0, do: {:error, :not_found}, else: :ok
  end

  @doc """
  Has this account signed in from this `{ip, user_agent}` pair before?

  Pure so the new-device heads-up is decided in one place and unit-
  testable in isolation. A fingerprint with no IP *and* no UA (nothing
  to recognise a device by) is treated as already-known — silence beats
  a false "new device" alarm. Otherwise the device is new exactly when
  no prior session shares this pair.
  """
  @spec new_device?({String.t() | nil, String.t() | nil}, [{String.t() | nil, String.t() | nil}]) ::
          boolean()
  def new_device?({nil, nil}, _prior), do: false
  def new_device?(fingerprint, prior), do: fingerprint not in prior

  defp prior_fingerprints(account_id) do
    from(s in Session, where: s.account_id == ^account_id, select: {s.ip_text, s.user_agent})
    |> Repo.all()
  end

  # One plain mail to the account's own verified address — no push, no
  # in-app badge, no count. Best-effort: a send that fails just means the
  # heads-up didn't go, the login already stands. Skipped silently when
  # there's no verified address to mail (passwordless accounts always
  # have one, but a half-set-up account may not yet).
  defp notify_new_device(account_id, ip) do
    case Repo.get(Account, account_id) do
      %Account{email_verified_at: %DateTime{}, email: email} = account when is_binary(email) ->
        _ = SukhiFedi.Auth.LoginNotice.deliver(account, ip)
        :ok

      _ ->
        :ok
    end
  end

  # 招待してくれた人を、ひとつだけフォローする。
  #
  # 繋がりのためでもあるけれど、**本体は招待した側への知らせ**のほう。
  # いままで、コードを渡したあと、その人が来たのかどうか分かる道が無かった。
  # follow 通知なら、よその実装のアプリでもそのまま読める(専用の通知型を
  # 作ると、そこだけ誰にも見えなくなる)。
  #
  # 片方向だけ。招待した側が自動でフォローバックすることはしない ──
  # そちらは、その人が選ぶこと。
  #
  # トランザクションの**外**。ここで転んでも、登録そのものは通す。
  # フォロー一本のために、入れた account を巻き戻すほうが重い。
  #
  # `on_behalf_of_id` があればそちらを優先する。管理者が誰かの代理で出した
  # 招待は、繋がるべき相手が発行者ではなく、その「誰か」なので。
  defp follow_inviter(%Account{} = newcomer, invite) do
    inviter_id = Map.get(invite, :on_behalf_of_id) || Map.get(invite, :issued_by_id)

    if is_integer(inviter_id) and inviter_id != newcomer.id do
      # 鍵つきの相手なら pending で止まる ── request_follow がその判断を
      # 持っているので、こちらで follow 行を作らない。冪等でもある。
      case SukhiFedi.Social.request_follow(newcomer, inviter_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.info("招待した人をフォローできず (#{inspect(reason)})")
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("招待した人のフォローで転んだ: #{Exception.message(error)}")
      :ok
  end

end
