# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.OAuth do
  @moduledoc """
  OAuth 2.0 server.

  Tokens are 32 random bytes, base64url-encoded, returned in plaintext to
  the client exactly once at mint time. Only the SHA-256 hash is stored —
  same pattern as `sessions.token_hash` — so a DB read leak does not yield
  usable bearer tokens. Constant-time lookup via the unique index on
  `oauth_access_tokens.token_hash`.

  Reachable from the api plugin node via
  `SukhiApi.GatewayRpc.call(SukhiFedi.OAuth, :fun, [args])`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SukhiFedi.{Outbox, Repo}
  alias SukhiFedi.Schema.{OauthAccessToken, OauthApp, OauthAuthorizationCode}

  # 10-minute lifetime per RFC 6749 §4.1.2
  @code_ttl_seconds 600

  # ── apps ─────────────────────────────────────────────────────────────────

  @doc """
  Register a new OAuth client app. Returns the app plus the plaintext
  `client_secret`. The plaintext is **only** available in this return
  value; the DB stores its SHA-256 hash.

  Emits `sns.outbox.oauth.app_registered` so future audit/moderation
  addons can react.
  """
  @spec register_app(map()) ::
          {:ok, %{app: OauthApp.t(), client_secret: String.t()}}
          | {:error, Ecto.Changeset.t()}
  def register_app(%{} = params) do
    client_id = generate_token()
    client_secret = generate_token()

    attrs = %{
      client_id: client_id,
      client_secret_hash: hash(client_secret),
      name: params[:name] || params["client_name"] || params["name"],
      redirect_uri: params[:redirect_uris] || params["redirect_uris"] || "",
      scopes: normalize_scopes(params[:scopes] || params["scopes"]),
      website: params[:website] || params["website"],
      owner_account_id: params[:owner_account_id]
    }

    Multi.new()
    |> Multi.insert(:app, OauthApp.changeset(%OauthApp{}, attrs))
    |> Outbox.enqueue_multi(
      :outbox_event,
      "sns.outbox.oauth.app_registered",
      "oauth_app",
      & &1.app.id,
      fn %{app: app} ->
        %{app_id: app.id, name: app.name, owner_account_id: app.owner_account_id}
      end
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{app: app}} -> {:ok, %{app: app, client_secret: client_secret}}
      {:error, :app, %Ecto.Changeset{} = cs, _} -> {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @spec find_app_by_client_id(String.t()) :: {:ok, OauthApp.t()} | {:error, :not_found}
  def find_app_by_client_id(client_id) when is_binary(client_id) do
    case Repo.get_by(OauthApp, client_id: client_id) do
      nil -> {:error, :not_found}
      app -> {:ok, app}
    end
  end

  @spec verify_app_secret(OauthApp.t(), String.t()) :: :ok | {:error, :invalid_client}
  def verify_app_secret(%OauthApp{client_secret_hash: hash}, client_secret)
      when is_binary(client_secret) do
    if Plug.Crypto.secure_compare(hash, hash(client_secret)) do
      :ok
    else
      {:error, :invalid_client}
    end
  end

  # ── authorization codes ──────────────────────────────────────────────────

  @doc """
  Mint an authorization code for the given app/account/redirect_uri.
  Returns the plaintext code (only here; DB stores its hash). Code expires
  in #{@code_ttl_seconds} seconds.
  """
  @spec create_authorization_code(OauthApp.t(), SukhiFedi.Schema.Account.t(), map()) ::
          {:ok, %{code: String.t(), state: String.t() | nil}}
          | {:error, :invalid_redirect_uri | :invalid_scope}
  def create_authorization_code(%OauthApp{} = app, %{id: account_id}, %{} = params) do
    redirect_uri = params[:redirect_uri] || params["redirect_uri"]
    scopes = normalize_scopes(params[:scopes] || params["scopes"] || app.scopes)
    state = params[:state] || params["state"]

    with :ok <- check_redirect_uri(app, redirect_uri),
         :ok <- check_scope_subset(scopes, app.scopes) do
      code = generate_token()
      expires_at = utc_now() |> DateTime.add(@code_ttl_seconds, :second)

      {:ok, _} =
        %OauthAuthorizationCode{}
        |> OauthAuthorizationCode.changeset(%{
          code_hash: hash(code),
          app_id: app.id,
          account_id: account_id,
          redirect_uri: redirect_uri,
          scopes: scopes,
          expires_at: expires_at
        })
        |> Repo.insert()

      {:ok, %{code: code, state: state}}
    end
  end

  # ── token exchange ───────────────────────────────────────────────────────

  @doc """
  Exchange an authorization code for an access token (RFC 6749 §4.1.3).
  Idempotency: a code can be redeemed exactly once — replay returns
  `{:error, :invalid_grant}`.
  """
  @spec exchange_code_for_token(map()) ::
          {:ok, map()}
          | {:error, :invalid_grant | :invalid_client | :invalid_redirect_uri}
  def exchange_code_for_token(%{} = params) do
    client_id = params[:client_id] || params["client_id"]
    client_secret = params[:client_secret] || params["client_secret"]
    code = params[:code] || params["code"]
    redirect_uri = params[:redirect_uri] || params["redirect_uri"]

    with {:ok, app} <- find_app_by_client_id(client_id),
         :ok <- verify_app_secret(app, client_secret),
         {:ok, code_row} <- claim_code(code, app.id),
         :ok <- check_redirect_uri_equals(redirect_uri, code_row.redirect_uri) do
      mint_token(app.id, code_row.account_id, code_row.scopes, refresh: true)
    end
  end

  @doc """
  Refresh-token grant (RFC 6749 §6). The refresh token rotates: a new
  refresh token is minted and the old one is revoked atomically.
  """
  @spec refresh_token_grant(map()) ::
          {:ok, map()} | {:error, :invalid_grant | :invalid_client}
  def refresh_token_grant(%{} = params) do
    client_id = params[:client_id] || params["client_id"]
    client_secret = params[:client_secret] || params["client_secret"]
    refresh_token = params[:refresh_token] || params["refresh_token"]

    with {:ok, app} <- find_app_by_client_id(client_id),
         :ok <- verify_app_secret(app, client_secret),
         {:ok, old} <- find_refresh_token(refresh_token, app.id) do
      _ =
        OauthAccessToken
        |> where([t], t.id == ^old.id)
        |> Repo.update_all(set: [revoked_at: utc_now()])

      mint_token(app.id, old.account_id, old.scopes, refresh: true)
    end
  end

  @doc """
  Client-credentials grant (RFC 6749 §4.4). No end-user; token has
  `account_id IS NULL` and is intended for app-to-server calls
  (e.g. `POST /api/v1/apps/verify_credentials`, public reads).
  """
  @spec client_credentials_grant(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :invalid_client | :invalid_scope}
  def client_credentials_grant(client_id, client_secret, requested_scopes \\ nil) do
    with {:ok, app} <- find_app_by_client_id(client_id),
         :ok <- verify_app_secret(app, client_secret) do
      scopes = normalize_scopes(requested_scopes || app.scopes)

      with :ok <- check_scope_subset(scopes, app.scopes) do
        mint_token(app.id, nil, scopes, refresh: false)
      end
    else
      # `find_app_by_client_id/1` distinguishes "no row" as `:not_found`,
      # but the OAuth grant API speaks only RFC 6749's `invalid_client`.
      # Same normalization happens upstream in `authorization_code_grant`.
      {:error, :not_found} -> {:error, :invalid_client}
      other -> other
    end
  end

  # ── bearer verification ──────────────────────────────────────────────────

  @doc """
  Verify a bearer token. Returns the bound account (nil for
  client_credentials), the issuing app, and the granted scopes split on
  whitespace. Updates `last_used_at` opportunistically (best-effort).
  """
  @spec verify_bearer(String.t()) ::
          {:ok, %{account: term(), app: OauthApp.t(), scopes: [String.t()]}}
          | {:error, :invalid_token | :expired | :revoked}
  def verify_bearer(token) when is_binary(token) do
    h = hash(token)

    case Repo.get_by(OauthAccessToken, token_hash: h) do
      nil ->
        {:error, :invalid_token}

      %OauthAccessToken{revoked_at: %DateTime{}} ->
        {:error, :revoked}

      %OauthAccessToken{expires_at: %DateTime{} = exp} = tok ->
        if DateTime.compare(exp, utc_now()) == :lt do
          {:error, :expired}
        else
          load_token(tok)
        end

      %OauthAccessToken{} = tok ->
        load_token(tok)
    end
  end

  # ── revoke ───────────────────────────────────────────────────────────────

  @doc """
  Revoke a token (RFC 7009). Always returns `:ok` — the spec mandates
  idempotent revocation even for unknown tokens, so callers can't probe
  for valid token values.
  """
  @spec revoke_token(map()) :: :ok
  def revoke_token(%{} = params) do
    client_id = params[:client_id] || params["client_id"]
    client_secret = params[:client_secret] || params["client_secret"]
    token = params[:token] || params["token"]

    with {:ok, app} <- find_app_by_client_id(client_id),
         :ok <- verify_app_secret(app, client_secret),
         token when is_binary(token) <- token do
      h = hash(token)

      _ =
        from(t in OauthAccessToken,
          where: t.app_id == ^app.id and (t.token_hash == ^h or t.refresh_token_hash == ^h)
        )
        |> Repo.update_all(set: [revoked_at: utc_now()])
    end

    :ok
  end

  @doc """
  Mint an access token for a freshly-signed-up account. Called by the
  `POST /api/v1/accounts` capability after `LocalAccounts.create/1`
  succeeds: the SPA needs a Bearer token immediately so it can drop
  the user into the timeline without a second redirect through
  `/oauth/authorize`.
  """
  @spec issue_initial_token(integer(), integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def issue_initial_token(app_id, account_id, scopes)
      when is_integer(app_id) and is_integer(account_id) and is_binary(scopes) do
    # Enforce the app's scope ceiling here too (the other grants already
    # do), so signup can't mint a token with scopes beyond what the app
    # registered.
    case Repo.get(OauthApp, app_id) do
      nil ->
        {:error, :invalid_client}

      %OauthApp{} = app ->
        with :ok <- check_scope_subset(scopes, app.scopes) do
          mint_token(app_id, account_id, scopes, refresh: true)
        end
    end
  end

  @doc """
  Mint the one key of a token-only account (`LocalAccounts.create_bot/2`).

  No refresh token and no expiry: the account has no password, no
  email and no session, so an expired token would lock it out for
  good with nobody to notice. The trade for "valid until revoked" is
  that an admin holds the ring — `revoke_account_tokens/1` plus a new
  mint is how the key turns (`LocalAccounts.rotate_bot_token/2`).
  """
  @spec issue_bot_token(integer(), integer()) :: {:ok, map()}
  def issue_bot_token(app_id, account_id) when is_integer(app_id) and is_integer(account_id) do
    mint_token(app_id, account_id, "read write", refresh: false, expires: false)
  end

  @doc """
  Mint one more access token for an ordinary account, valid for
  `ttl_seconds` (the caller has already bounded it). Nothing else the
  account holds is touched — a personal token is added, never a swap.
  """
  @spec issue_personal_token(integer(), integer(), pos_integer()) :: {:ok, map()}
  def issue_personal_token(app_id, account_id, ttl_seconds)
      when is_integer(app_id) and is_integer(account_id) and is_integer(ttl_seconds) and
             ttl_seconds > 0 do
    mint_token(app_id, account_id, "read write", refresh: false, ttl: ttl_seconds)
  end

  @doc """
  Revoke every live token bound to an account. Returns how many turned.
  """
  @spec revoke_account_tokens(integer()) :: non_neg_integer()
  def revoke_account_tokens(account_id) when is_integer(account_id) do
    {n, _} =
      from(t in OauthAccessToken, where: t.account_id == ^account_id and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: utc_now()])

    n
  end

  # ── internals ────────────────────────────────────────────────────────────

  # Access tokens previously never expired (expires_at NULL), so a leaked
  # bearer was valid forever. Give every minted token a finite absolute
  # lifetime; verify_bearer already rejects an expired one. The one
  # exception is `expires: false` for token-only accounts (see
  # `issue_bot_token/2`).
  @token_ttl_seconds 90 * 24 * 60 * 60

  defp mint_token(app_id, account_id, scopes, opts) do
    with_refresh? = Keyword.fetch!(opts, :refresh)
    access = generate_token()
    refresh = if with_refresh?, do: generate_token(), else: nil

    ttl = Keyword.get(opts, :ttl, @token_ttl_seconds)

    expires_at =
      if Keyword.get(opts, :expires, true),
        do: utc_now() |> DateTime.add(ttl, :second),
        else: nil

    attrs = %{
      token_hash: hash(access),
      refresh_token_hash: refresh && hash(refresh),
      app_id: app_id,
      account_id: account_id,
      scopes: scopes,
      expires_at: expires_at
    }

    {:ok, _row} =
      %OauthAccessToken{}
      |> OauthAccessToken.changeset(attrs)
      |> Repo.insert()

    {:ok,
     %{
       access_token: access,
       refresh_token: refresh,
       token_type: "Bearer",
       scope: scopes,
       created_at: System.system_time(:second),
       expires_in: expires_at && ttl
     }}
  end

  # Atomically claim a code: the same SQL statement marks it used and
  # returns it only if it was previously unused and unexpired. This
  # closes the replay race even with multiple concurrent token requests.
  defp claim_code(code, app_id) when is_binary(code) do
    h = hash(code)
    now = utc_now()

    {n, rows} =
      from(c in OauthAuthorizationCode,
        where:
          c.code_hash == ^h and c.app_id == ^app_id and is_nil(c.used_at) and
            c.expires_at > ^now,
        select: c
      )
      |> Repo.update_all(set: [used_at: now])

    case {n, rows} do
      {1, [row]} -> {:ok, row}
      _ -> {:error, :invalid_grant}
    end
  end

  defp claim_code(_, _), do: {:error, :invalid_grant}

  defp find_refresh_token(token, app_id) when is_binary(token) do
    h = hash(token)

    case Repo.get_by(OauthAccessToken, refresh_token_hash: h, app_id: app_id) do
      nil -> {:error, :invalid_grant}
      %OauthAccessToken{revoked_at: %DateTime{}} -> {:error, :invalid_grant}
      tok -> {:ok, tok}
    end
  end

  defp find_refresh_token(_, _), do: {:error, :invalid_grant}

  defp load_token(%OauthAccessToken{} = tok) do
    app = Repo.get(OauthApp, tok.app_id)

    account =
      case tok.account_id do
        nil -> nil
        id -> Repo.get(SukhiFedi.Schema.Account, id)
      end

    # best-effort touch
    _ =
      OauthAccessToken
      |> where([t], t.id == ^tok.id)
      |> Repo.update_all(set: [last_used_at: utc_now()])

    {:ok, %{account: account, app: app, scopes: split_scopes(tok.scopes)}}
  end

  defp check_redirect_uri(%OauthApp{redirect_uri: registered}, requested)
       when is_binary(requested) do
    if requested in String.split(registered, ~r/\s+/, trim: true) do
      :ok
    else
      {:error, :invalid_redirect_uri}
    end
  end

  defp check_redirect_uri(_, _), do: {:error, :invalid_redirect_uri}

  defp check_redirect_uri_equals(a, b) when is_binary(a) and is_binary(b) and a == b, do: :ok
  defp check_redirect_uri_equals(_, _), do: {:error, :invalid_redirect_uri}

  defp check_scope_subset(requested, granted) do
    req = MapSet.new(split_scopes(requested))
    grant = MapSet.new(split_scopes(granted))

    if MapSet.subset?(req, grant), do: :ok, else: {:error, :invalid_scope}
  end

  defp normalize_scopes(nil), do: "read"
  defp normalize_scopes(""), do: "read"
  defp normalize_scopes(s) when is_binary(s), do: s |> split_scopes() |> Enum.join(" ")
  defp normalize_scopes(list) when is_list(list), do: Enum.join(list, " ")

  defp split_scopes(s) when is_binary(s), do: String.split(s, ~r/\s+/, trim: true)
  defp split_scopes(_), do: []

  defp generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp hash(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
