# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.AccessLogPlug do
  @moduledoc """
  One-line access log with remote-server fingerprint: method, path,
  status, elapsed, client ip (honouring `cf-connecting-ip` since every
  request is proxied through cloudflared), user-agent, accept header,
  and whether the request carried an HTTP signature. Useful when a
  remote fediverse server is deref'ing our endpoints and we need to
  see what shape of request it sent.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    start = System.monotonic_time(:millisecond)
    # method は入り口で控える ── この後ろの Plug.Head が HEAD を GET に
    # 書き換えるので、返すときに読むと HEAD が一つも残らない。
    method = conn.method

    register_before_send(conn, fn conn ->
      elapsed = System.monotonic_time(:millisecond) - start
      ua = header(conn, "user-agent")
      accept = header(conn, "accept")
      sig = if header(conn, "signature") == "-", do: "unsigned", else: "signed"
      remote = SukhiFedi.Web.RateLimitPlug.peer_id(conn)
      query = if conn.query_string in [nil, ""], do: "", else: "?#{conn.query_string}"

      Logger.info(
        "ACCESS #{method} #{conn.request_path}#{query} -> #{conn.status} " <>
          "(#{elapsed}ms) ip=#{remote} ua=#{inspect(ua)} accept=#{inspect(accept)} #{sig}"
      )

      conn
    end)
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      _ -> "-"
    end
  end
end
