# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.WtController do
  @moduledoc """
  `GET /api/wt` — WebTransport のエッジ（karutte, `webtransport.f3liz.casa`）へ繋ぐための
  発券口。認証済みクライアントに `{endpoint, ticket, feeds}` を返す。

  SPA は ticket を付けて `<endpoint>?ticket=<token>` に WebTransport で繋ぎ、karutte は
  公開鍵でローカル検証する（`SukhiFedi.WtTicket` / karutte 側 `Karutte.Ticket`）。SSE と同じく
  bearer はここで直接検証する（gateway が Postgres を共有＝プラグインノード往復なし）。
  """

  import Plug.Conn

  alias SukhiFedi.OAuth
  alias SukhiFedi.Web.BearerToken
  alias SukhiFedi.WtTicket

  # チケットに載せる feed。**発券はここが正**（`mint/2` に明示で渡すので、
  # `WtTicket` 側の `@default_feeds` はフォールバックに落ちない）。
  # karutte が知らない feed 名を渡しても、向こうの `subject_for/2` が nil を
  # 返してその feed が開かないだけなので、順番を合わせる必要はない。
  @feeds ["local", "user", "direct"]

  def wt(conn, _opts) do
    case authenticate(conn) do
      {:ok, account_id} ->
        case WtTicket.mint(account_id, feeds: @feeds) do
          {:ok, ticket} ->
            json(conn, 200, %{endpoint: endpoint(), ticket: ticket, feeds: @feeds})

          {:error, _} ->
            json(conn, 503, %{error: "WebTransport is not configured"})
        end

      :error ->
        json(conn, 401, %{error: "This method requires an authenticated user"})
    end
  end

  defp endpoint,
    do: Application.get_env(:sukhi_fedi, :wt_endpoint, "https://webtransport.f3liz.casa/wt")

  defp authenticate(conn) do
    with token when is_binary(token) <- BearerToken.extract(conn),
         {:ok, %{account: %{id: account_id}}} <- OAuth.verify_bearer(token) do
      {:ok, account_id}
    else
      _ -> :error
    end
  end

  defp json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(map))
  end
end
