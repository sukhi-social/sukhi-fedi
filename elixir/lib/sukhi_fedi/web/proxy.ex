# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Proxy do
  @moduledoc """
  Hands a request to a web upstream and streams the answer back.

  Every web crosses the gateway through this one function, so the things
  that must hold for all of them are decided here and nowhere else:

    * **`Host` stays the browser's.** A web checks `Origin` against `Host`
      for its CSRF rule; rewrite it and every form POST is a 403.
    * **`x-forwarded-*` are the gateway's.** What the client sent is
      dropped; the web is told host / proto / client address by us.
    * **Cookies cross only by name.** The upstream's `cookies` list (its
      `web.json`) is the whole allowlist, in both directions. A web cannot
      read `session_token`, and cannot overwrite it with a `Set-Cookie`.
    * **Bodies stream** both ways. Nothing here buffers an upload.
    * **A web that does not answer is a 503 page**, never an empty one.

  The request body is read from the connection, so the caller must route
  here **before** `Plug.Parsers` for any method that has one.
  """

  import Plug.Conn
  require Logger

  # RFC 9110 hop-by-hop, plus what the client leg decides for itself.
  @hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer
          transfer-encoding upgrade)
  @drop_request ~w(host cookie x-forwarded-host x-forwarded-proto x-forwarded-for)
  @drop_response ~w(content-length set-cookie)

  @spec forward(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def forward(conn, %{name: name, url: base} = upstream) do
    url = base <> conn.request_path <> query(conn)
    req = Finch.build(method(conn), url, request_headers(conn, upstream), request_body(conn))

    acc = %{conn: conn, sent?: false, status: nil, headers: []}

    case Finch.stream(req, SukhiFedi.Finch, acc, &on_event(&1, &2, upstream), receive_timeout: 20_000) do
      {:ok, %{conn: conn, sent?: true}} ->
        conn

      {:ok, acc} ->
        # Headers arrived but no body chunk did (204, 304, a redirect).
        acc.conn |> prepare(acc.status, acc.headers, upstream, name) |> send_resp(acc.status, "")

      {:error, reason, %{sent?: false, conn: conn}} ->
        Logger.warning("web upstream #{name} unreachable: #{inspect(reason)}")
        unavailable(conn)

      {:error, reason, %{conn: conn}} ->
        # Already streaming: all that is left is to stop. The client sees
        # a truncated body, which is honest.
        Logger.warning("web upstream #{name} broke mid-response: #{inspect(reason)}")
        halt(conn)
    end
  end

  defp on_event({:status, status}, acc, _up), do: %{acc | status: status}
  defp on_event({:headers, headers}, acc, _up), do: %{acc | headers: acc.headers ++ headers}

  defp on_event({:data, data}, %{sent?: false} = acc, up) do
    conn = prepare(acc.conn, acc.status, acc.headers, up, up.name) |> send_chunked(acc.status)
    {:ok, conn} = chunk(conn, data)
    %{acc | conn: conn, sent?: true}
  end

  defp on_event({:data, data}, acc, _up) do
    {:ok, conn} = chunk(acc.conn, data)
    %{acc | conn: conn}
  end

  defp on_event(_other, acc, _up), do: acc

  # Response headers: all but hop-by-hop / length / cookies, and only the
  # allowed cookies by name.
  defp prepare(conn, _status, headers, up, name) do
    # `put_resp_header`, not prepend: Plug starts every response with a
    # default `cache-control`, and the web's own must replace it, not sit
    # beside it. A header the web repeats (`vary`, `link`) is joined.
    conn =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
      |> Enum.reject(fn {k, _} -> k in @hop or k in @drop_response end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.reduce(conn, fn {k, vs}, c -> put_resp_header(c, k, Enum.join(vs, ", ")) end)

    conn =
      headers
      |> Enum.filter(fn {k, v} -> String.downcase(k) == "set-cookie" and allowed_set_cookie?(v, up) end)
      |> Enum.reduce(conn, fn {_, v}, c -> prepend_resp_headers(c, [{"set-cookie", v}]) end)

    put_resp_header(conn, "x-static-source", "upstream:" <> name)
  end

  defp request_headers(conn, up) do
    kept =
      for {k, v} <- conn.req_headers, k not in @hop, k not in @drop_request, do: {k, v}

    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    forwarded_for =
      case get_req_header(conn, "x-forwarded-for") do
        [prior | _] -> prior <> ", " <> ip
        [] -> ip
      end

    proto =
      case get_req_header(conn, "x-forwarded-proto") do
        [p | _] -> p
        [] -> to_string(conn.scheme)
      end

    cookie =
      case filter_cookie(get_req_header(conn, "cookie"), up.cookies) do
        "" -> []
        c -> [{"cookie", c}]
      end

    [
      {"host", host_header(conn)},
      {"x-forwarded-host", host_header(conn)},
      {"x-forwarded-proto", proto},
      {"x-forwarded-for", forwarded_for}
      | cookie ++ kept
    ]
  end

  defp host_header(conn) do
    case get_req_header(conn, "host") do
      [h | _] -> h
      [] -> conn.host
    end
  end

  # The names an upstream may see. Cookie headers are `a=1; b=2`.
  defp filter_cookie(headers, allowed) do
    headers
    |> Enum.flat_map(&String.split(&1, ";", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn pair -> cookie_name(pair) in allowed end)
    |> Enum.join("; ")
  end

  defp allowed_set_cookie?(value, up), do: cookie_name(value) in up.cookies

  defp cookie_name(pair), do: pair |> String.split("=", parts: 2) |> hd() |> String.trim()

  defp method(%Plug.Conn{method: "HEAD"}), do: "GET"
  defp method(%Plug.Conn{method: m}), do: m

  defp request_body(%Plug.Conn{method: m}) when m in ["GET", "HEAD"], do: nil

  defp request_body(conn) do
    {:stream,
     Stream.resource(
       fn -> conn end,
       fn
         :done ->
           {:halt, :done}

         c ->
           case read_body(c, length: 1_000_000) do
             {:more, chunk, c} -> {[chunk], c}
             {:ok, chunk, _c} -> {[chunk], :done}
             {:error, _} -> {:halt, :done}
           end
       end,
       fn _ -> :ok end
     )}
  end

  defp query(%Plug.Conn{query_string: ""}), do: ""
  defp query(%Plug.Conn{query_string: q}), do: "?" <> q

  defp unavailable(conn) do
    conn
    |> put_resp_content_type("text/html; charset=utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(503, ~s|<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>sukhi</title><body style="font-family:sans-serif;padding:3rem 1.5rem;line-height:1.8"><p>いま、頁を描く手が休んでいます。すこししてから、もういちど開いてみてください。</p></body></html>|)
  end
end
