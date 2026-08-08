# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.SessionCookieTest do
  @moduledoc """
  Multi-account layout: `session_token` (primary) + `session_tokens`
  (the others). The routing that shows the account picker on
  `/oauth/authorize` lives on the `api` node and is tested there
  (fake-RPC'd against this module); this covers the real thing —
  `mint_additional/2`, `all_sessions/1`, `promote/2`, `remove/2` —
  against a real session table.
  """

  use SukhiFedi.IntegrationCase, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag :integration

  alias SukhiFedi.LocalAccounts
  alias SukhiFedi.Web.Auth.SessionCookie

  defp new_account! do
    n = System.unique_integer([:positive])
    {:ok, account} = LocalAccounts.create_admin("mac_#{n}", "long-enough-pass")
    account
  end

  defp set_cookie(conn, name, value), do: put_req_header(conn, "cookie", "#{name}=#{value}")

  # `resp_cookies` directly, not the rendered `set-cookie` header — Plug
  # only serializes that at send_resp time, which these tests never call
  # (they inspect the conn `SessionCookie` handed back, not a live
  # response). A cleared cookie (`delete_resp_cookie/3`) still has a
  # `:value` key, just `""`, so an empty value counts as absent here too.
  defp cookie_pair(conn, name) do
    case conn.resp_cookies[name] do
      %{value: v} when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  test "mint/2 sets only the primary cookie" do
    account = new_account!()
    conn = conn(:get, "/") |> SessionCookie.mint(account)
    assert cookie_pair(conn, "session_token")
    refute cookie_pair(conn, "session_tokens")
  end

  test "mint_additional/2 with no primary yet just becomes primary" do
    account = new_account!()
    conn = conn(:get, "/") |> SessionCookie.mint_additional(account)
    assert cookie_pair(conn, "session_token")
    refute cookie_pair(conn, "session_tokens")
  end

  test "mint_additional/2 alongside a primary appends to the side list, primary untouched" do
    a = new_account!()
    b = new_account!()

    {:ok, tok_a} = LocalAccounts.create_session(a)

    conn =
      conn(:get, "/")
      |> set_cookie("session_token", tok_a)
      |> SessionCookie.mint_additional(b)

    # The primary is untouched — literally not re-set, since the browser
    # already has it from before and there's nothing new to tell it.
    refute Map.has_key?(conn.resp_cookies, "session_token")
    extras_value = cookie_pair(conn, "session_tokens")
    assert is_binary(extras_value)
    assert SessionCookie.decode_extra(extras_value) |> length() == 1
  end

  test "all_sessions/1 resolves primary + extras, primary first, and drops a dead token" do
    a = new_account!()
    b = new_account!()
    {:ok, tok_a} = LocalAccounts.create_session(a)
    {:ok, tok_b} = LocalAccounts.create_session(b)

    conn =
      conn(:get, "/")
      |> set_cookie("session_token", tok_a)
      |> put_req_header("cookie", "session_token=#{tok_a}; session_tokens=#{SessionCookie.encode_extra([tok_b, "garbage-not-a-real-token"])}")

    sessions = SessionCookie.all_sessions(conn)
    assert Enum.map(sessions, & &1.account.id) == [a.id, b.id]
    assert Enum.find(sessions, &(&1.account.id == a.id)).primary?
    refute Enum.find(sessions, &(&1.account.id == b.id)).primary?
  end

  test "promote/2 swaps which one is primary" do
    a = new_account!()
    b = new_account!()
    {:ok, tok_a} = LocalAccounts.create_session(a)
    {:ok, tok_b} = LocalAccounts.create_session(b)

    conn =
      conn(:get, "/")
      |> put_req_header(
        "cookie",
        "session_token=#{tok_a}; session_tokens=#{SessionCookie.encode_extra([tok_b])}"
      )
      |> SessionCookie.promote(b.id)

    assert cookie_pair(conn, "session_token") == tok_b
    assert SessionCookie.decode_extra(cookie_pair(conn, "session_tokens")) == [tok_a]
  end

  test "promote/2 is a no-op for an account this browser doesn't hold" do
    a = new_account!()
    stranger = new_account!()
    {:ok, tok_a} = LocalAccounts.create_session(a)

    conn =
      conn(:get, "/")
      |> set_cookie("session_token", tok_a)
      |> SessionCookie.promote(stranger.id)

    assert conn.resp_cookies == %{}
  end

  test "remove/2 drops just one account and revokes its session row" do
    a = new_account!()
    b = new_account!()
    {:ok, tok_a} = LocalAccounts.create_session(a)
    {:ok, tok_b} = LocalAccounts.create_session(b)

    conn =
      conn(:get, "/")
      |> put_req_header(
        "cookie",
        "session_token=#{tok_a}; session_tokens=#{SessionCookie.encode_extra([tok_b])}"
      )
      |> SessionCookie.remove(b.id)

    assert cookie_pair(conn, "session_token") == tok_a
    refute cookie_pair(conn, "session_tokens")
    assert is_nil(SukhiFedi.Accounts.get_account_by_session_token(tok_b))
  end

  test "remove/2 on the only account clears both cookies (same as drop/1)" do
    a = new_account!()
    {:ok, tok_a} = LocalAccounts.create_session(a)

    conn =
      conn(:get, "/")
      |> set_cookie("session_token", tok_a)
      |> SessionCookie.remove(a.id)

    assert cookie_pair(conn, "session_token") in [nil, ""]
  end

  test "decode_extra/1 treats malformed values as empty, not a crash" do
    assert SessionCookie.decode_extra(nil) == []
    assert SessionCookie.decode_extra("") == []
    assert SessionCookie.decode_extra("not-base64!!") == []
    assert SessionCookie.decode_extra(Base.url_encode64("not json", padding: false)) == []
  end
end
