# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Auth.SessionCookie do
  @moduledoc """
  The `session_token` cookie, in one place: every login door (password,
  email code, passkey, TOTP step) mints it here with the same flags,
  and the management endpoints resolve it back to an account here.

  This cookie is the *first-party* proof. OAuth bearers — which any
  third-party app can hold — are deliberately not accepted where this
  module is the gate: a leaked bearer must not be able to re-wire the
  account's login factors.

  Multi-account: `session_token` stays exactly what it always was — the
  *primary* session, the one every existing caller (`/settings/*`, the
  plain `/oauth/authorize` consent flow) keeps reading unchanged. A
  second cookie, `session_tokens` (plural — a JSON array, base64url'd
  so commas/brackets never touch raw cookie syntax), holds the *other*
  accounts this browser has also signed into via `mint_additional/2`.
  Nothing reads it unless it's asking (`all_sessions/1`), so a browser
  that never adds a second account never sees a behavior change at all.
  """

  import Plug.Conn

  alias SukhiFedi.{Accounts, LocalAccounts}
  alias SukhiFedi.Web.RateLimitPlug

  @cookie "session_token"
  @extra_cookie "session_tokens"
  @max_age 60 * 60 * 24 * 30
  # Primary + this many others — a sane ceiling on the side cookie's size,
  # not a claim anyone needs this many accounts in one browser.
  @max_extra 7

  @spec mint(Plug.Conn.t(), SukhiFedi.Schema.Account.t()) :: Plug.Conn.t()
  def mint(conn, account) do
    {:ok, token} = LocalAccounts.create_session(account, device_context(conn))
    put_primary_cookie(conn, token)
  end

  @doc """
  Mint a session for `account` *alongside* whatever is already primary,
  rather than replacing it — "sign in to another account" instead of a
  fresh login. With no primary session yet, there's nothing to add to;
  this just becomes the primary, same as `mint/2`.
  """
  @spec mint_additional(Plug.Conn.t(), SukhiFedi.Schema.Account.t()) :: Plug.Conn.t()
  def mint_additional(conn, account) do
    conn = fetch_cookies(conn)

    if conn.cookies[@cookie] in [nil, ""] do
      mint(conn, account)
    else
      {:ok, token} = LocalAccounts.create_session(account, device_context(conn))
      existing = decode_extra(conn.cookies[@extra_cookie])
      put_extra_cookie(conn, Enum.take([token | existing], @max_extra))
    end
  end

  @doc "Sign this browser out of every account it holds — both cookies, gone."
  @spec drop(Plug.Conn.t()) :: Plug.Conn.t()
  def drop(conn),
    do:
      conn
      |> delete_resp_cookie(@cookie, path: "/")
      |> delete_resp_cookie(@extra_cookie, path: "/")

  @type session :: %{
          account: SukhiFedi.Schema.Account.t(),
          token: String.t(),
          primary?: boolean()
        }

  @doc """
  Every account this browser is currently signed into: the primary
  first, then the others, each resolved from its cookie token. A token
  that no longer resolves (expired, revoked elsewhere) is silently
  dropped rather than surfaced — the cookie just stops naming it.
  """
  @spec all_sessions(Plug.Conn.t()) :: [session()]
  def all_sessions(conn) do
    conn = fetch_cookies(conn)
    resolve_all(conn.cookies[@cookie], decode_extra(conn.cookies[@extra_cookie]))
  end

  @doc """
  Pure counterpart of `all_sessions/1` — for `/oauth/authorize`, which
  runs on the `api` node and only ever has raw cookie *values* (from
  its own hand-rolled `Cookie:` header parse), never a `Plug.Conn` to
  read cookies from directly.
  """
  @spec resolve_all(String.t() | nil, [String.t()]) :: [session()]
  def resolve_all(primary_token, extra_tokens) do
    [{primary_token, true} | Enum.map(extra_tokens, &{&1, false})]
    |> Enum.reject(fn {t, _primary?} -> t in [nil, ""] end)
    |> Enum.map(fn {token, primary?} ->
      {token, primary?, Accounts.get_account_by_session_token(token)}
    end)
    |> Enum.reject(fn {_token, _primary?, account} -> is_nil(account) end)
    |> Enum.uniq_by(fn {_token, _primary?, account} -> account.id end)
    |> Enum.map(fn {token, primary?, account} ->
      %{account: account, token: token, primary?: primary?}
    end)
  end

  @doc """
  Make `account_id`'s session primary, moving whichever session was
  primary (if any) into the side list. A no-op if this browser has no
  live session for that account; idempotent if it's already primary.
  """
  @spec promote(Plug.Conn.t(), integer()) :: Plug.Conn.t()
  def promote(conn, account_id) do
    case layout_for_promote(all_sessions(conn), account_id) do
      :not_found -> conn
      {primary, extras} -> conn |> put_primary_cookie(primary) |> put_extra_cookie(extras)
    end
  end

  @doc "Pure layout math behind `promote/2` — see `resolve_all/2` for why `api` needs this split out."
  @spec layout_for_promote([session()], integer()) :: {String.t(), [String.t()]} | :not_found
  def layout_for_promote(sessions, account_id) do
    case Enum.find(sessions, &(&1.account.id == account_id)) do
      nil ->
        :not_found

      target ->
        {target.token,
         sessions |> Enum.reject(&(&1.account.id == account_id)) |> Enum.map(& &1.token)}
    end
  end

  @doc """
  Sign this browser out of just `account_id`, leaving its other
  accounts (if any) untouched. If the removed account was primary, the
  next remaining one takes its place; removing the last account clears
  both cookies (same end state as `drop/1`).
  """
  @spec remove(Plug.Conn.t(), integer()) :: Plug.Conn.t()
  def remove(conn, account_id) do
    sessions = all_sessions(conn)

    case Enum.find(sessions, &(&1.account.id == account_id)) do
      nil ->
        conn

      target ->
        LocalAccounts.revoke_session_by_token(target.token)

        case layout_for_remove(sessions, account_id) do
          {nil, []} -> drop(conn)
          {primary, extras} -> conn |> put_primary_cookie(primary) |> put_extra_cookie(extras)
        end
    end
  end

  @doc "Pure layout math behind `remove/2`."
  @spec layout_for_remove([session()], integer()) :: {String.t() | nil, [String.t()]} | :not_found
  def layout_for_remove(sessions, account_id) do
    if Enum.any?(sessions, &(&1.account.id == account_id)) do
      case Enum.reject(sessions, &(&1.account.id == account_id)) do
        [] -> {nil, []}
        [new_primary | rest] -> {new_primary.token, Enum.map(rest, & &1.token)}
      end
    else
      :not_found
    end
  end

  @doc "The signed-in account behind the request's cookie, or nil."
  @spec account(Plug.Conn.t()) :: SukhiFedi.Schema.Account.t() | nil
  def account(conn) do
    conn = fetch_cookies(conn)
    Accounts.get_account_by_session_token(conn.cookies[@cookie] || "")
  end

  @doc """
  The SHA-256 hash of the request's session cookie, or nil. The session
  list uses it to mark which row is *this* device — never the plaintext
  token, which only ever lives in the cookie.
  """
  @spec current_token_hash(Plug.Conn.t()) :: String.t() | nil
  def current_token_hash(conn) do
    conn = fetch_cookies(conn)

    case conn.cookies[@cookie] do
      token when is_binary(token) and token != "" ->
        :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

      _ ->
        nil
    end
  end

  # The device behind this login, for the session row + new-device
  # heads-up. The IP comes from the one shared resolver (`peer_id/1`),
  # never a second copy of the cf-connecting-ip dance.
  defp device_context(conn) do
    ua =
      case get_req_header(conn, "user-agent") do
        [value | _] when is_binary(value) -> value
        _ -> nil
      end

    %{ip_text: RateLimitPlug.peer_id(conn), user_agent: ua}
  end

  defp put_primary_cookie(conn, token) do
    put_resp_cookie(conn, @cookie, token,
      http_only: true,
      same_site: "Lax",
      secure: secure?(),
      max_age: @max_age,
      path: "/"
    )
  end

  defp put_extra_cookie(conn, []), do: delete_resp_cookie(conn, @extra_cookie, path: "/")

  defp put_extra_cookie(conn, tokens) do
    put_resp_cookie(conn, @extra_cookie, encode_extra(tokens),
      http_only: true,
      same_site: "Lax",
      secure: secure?(),
      max_age: @max_age,
      path: "/"
    )
  end

  @doc "The `session_tokens` cookie's raw value for a given token list — `api`'s side of the pair with `decode_extra/1`."
  @spec encode_extra([String.t()]) :: String.t()
  def encode_extra(tokens), do: tokens |> JSON.encode!() |> Base.url_encode64(padding: false)

  @doc """
  Decode the `session_tokens` cookie's raw value into a token list.
  Malformed/tampered values decode to `[]` — the side cookie is a cache
  of live DB sessions, never itself the source of truth, so losing it
  costs nothing but a re-add. Public (not `conn`-shaped) so `api`'s
  `/oauth/authorize`, which only has the raw `Cookie:` header, can
  reuse it over RPC instead of re-implementing the format.
  """
  @spec decode_extra(String.t() | nil) :: [String.t()]
  def decode_extra(value) do
    with value when is_binary(value) and value != "" <- value,
         {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, list} when is_list(list) <- JSON.decode(json) do
      Enum.filter(list, &is_binary/1)
    else
      _ -> []
    end
  end

  defp secure? do
    Application.get_env(:sukhi_fedi, :admin_session_secure, true)
  end
end
