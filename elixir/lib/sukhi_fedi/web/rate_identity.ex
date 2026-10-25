# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.RateIdentity do
  @moduledoc """
  Who a request is from, for the rate limiter — and only if that is worth
  knowing: a signed-in account at least `@mature_days` old.

  The global limit counts by IP, which makes everyone behind one address
  (a school, a carrier's NAT, a household) share a window and a penalty
  box. An account that has been here a month is counted by its own id
  instead. A new or anonymous caller stays on its IP, so a throwaway
  account cannot buy itself a window of its own.

  The check is in one place: `identify/1`, handed to `RateLimitPlug` as
  `:identify`. Only a credential the server itself verifies counts — a
  bearer token (`OAuth.verify_bearer/1`) or the `session_token` cookie
  (`Accounts.get_account_by_session_token/1`), the same two doors the api
  node opens. Anything else is nobody, and falls back to the IP.

  Two things keep this from becoming a database hole in front of the
  limiter:

    * the answer, for a token (hash), is kept `@ttl` seconds in
      `Cache.Ets` (`:rate_identity`) — so the DB is asked once per token
      per minute, not once per request;
    * an address may cause only `@lookups_per_min` such lookups a minute
      (its own Hammer bucket). A flood of made-up tokens spends that
      budget and is then simply not identified: it stays on its IP.

  A token revoked a moment ago still names its account for up to `@ttl`
  seconds. That only decides which bucket a request is counted in.
  """

  alias SukhiFedi.Cache.Ets
  alias SukhiFedi.Web.RateLimitPlug

  @table :rate_identity
  @ttl 60
  @mature_days 30
  @lookups_per_min 300

  @spec identify(Plug.Conn.t()) :: {:ok, integer()} | nil
  def identify(%Plug.Conn{} = conn) do
    case credential(conn) do
      nil -> nil
      {kind, token} -> cached(conn, kind, token)
    end
  end

  defp cached(conn, kind, token) do
    key = :crypto.hash(:sha256, token)

    case Ets.get(@table, key) do
      {:ok, answer} ->
        answer

      :miss ->
        if lookup_allowed?(conn) do
          answer = resolve(kind, token)
          Ets.put(@table, key, answer, @ttl)
          answer
        end
    end
  end

  defp lookup_allowed?(conn) do
    match?(
      {:allow, _},
      Hammer.check_rate("ident:#{RateLimitPlug.peer_id(conn)}", 60_000, @lookups_per_min)
    )
  end

  defp resolve(:bearer, token) do
    case SukhiFedi.OAuth.verify_bearer(token) do
      {:ok, %{account: account}} -> mature(account)
      _ -> nil
    end
  end

  defp resolve(:cookie, token), do: mature(SukhiFedi.Accounts.get_account_by_session_token(token))

  defp mature(%{id: id, created_at: %DateTime{} = created_at}) when is_integer(id) do
    if DateTime.diff(DateTime.utc_now(), created_at) >= @mature_days * 86_400, do: {:ok, id}
  end

  defp mature(_), do: nil

  # A bearer wins over the cookie, as it does in the api router.
  defp credential(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" ->
        {:bearer, token}

      _ ->
        case Plug.Conn.fetch_cookies(conn).cookies["session_token"] do
          token when is_binary(token) and token != "" -> {:cookie, token}
          _ -> nil
        end
    end
  end
end
