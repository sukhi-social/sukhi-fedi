# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.SSR do
  @moduledoc """
  The SPA's pages, rendered by a Node next door.

  When `SSR_URL` is set (natadeco: `http://natadeco-ssr:3000`), every
  request that used to get the empty SvelteKit shell is forwarded to
  that server instead, and its HTML comes back through here. Nothing
  else changes hands: the API, ActivityPub, streaming and static files
  stay with this BEAM, and the Node fetches its data from us over the
  container network (`INTERNAL_API_URL`).

  The request's `cookie` goes along, so the Node can hand the
  `session_token` to the API and render the signed-in view (the API
  reads that cookie as the viewer — `SukhiApi.Router`). Pages that
  only make sense signed in still opt out of SSR on their side
  (`export const ssr = false`) and come back as a shell.

  Unset, `render/1` is never reached: `serve_spa` keeps serving the
  static `index.html`, which is what sukhi's own frontend still is.
  """

  import Plug.Conn

  require Logger

  # Headers the renderer needs to make the same decisions a browser
  # would see: language (which dictionary), who is reading (cookie);
  # the crawler/markdown negotiation already happened before we got here.
  @forward ~w(accept accept-language user-agent cookie)

  # 描き手に、どの玄関から来た請求かを伝える。同じ Node が
  # natadeco.com と travel.natadeco.com の両方を描くので、host が
  # 無いと部屋を分けられない。
  defp forward_headers(conn) do
    kept = for {k, v} <- conn.req_headers, k in @forward, do: {k, v}
    [{"x-forwarded-host", conn.host}, {"x-forwarded-proto", "https"} | kept]
  end

  @spec enabled?() :: boolean()
  def enabled?, do: is_binary(url())

  @spec url() :: String.t() | nil
  def url do
    case System.get_env("SSR_URL") do
      nil -> nil
      "" -> nil
      u -> String.trim_trailing(u, "/")
    end
  end

  @doc """
  Fetch the page for `conn`'s path from the SSR server and send it.
  The renderer's status is passed through (404 for a board that
  isn't there, say). If the renderer can't be reached, answer 503 with
  a small plain page rather than an empty shell that would never fill.
  """
  @spec render(Plug.Conn.t()) :: Plug.Conn.t()
  def render(conn) do
    target = url() <> conn.request_path <> query(conn)

    headers = forward_headers(conn)

    case Req.get(target,
           headers: headers,
           finch: SukhiFedi.Finch,
           retry: false,
           redirect: false,
           decode_body: false,
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: status, body: body} = resp} ->
        conn
        |> put_resp_content_type(content_type(resp))
        # Cloudflare sits in front: HTML must not be cached across
        # people (it varies by language) or across builds (it names
        # content-hashed chunks).
        |> put_resp_header("cache-control", "no-cache, must-revalidate")
        |> put_resp_header("vary", "accept-language")
        |> put_resp_header("x-static-source", "ssr")
        |> maybe_location(resp)
        |> send_resp(status, body)

      {:error, reason} ->
        Logger.warning("ssr: renderer unreachable: #{inspect(reason)}")

        conn
        |> put_resp_content_type("text/html; charset=utf-8")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(503, unavailable())
    end
  end

  @doc """
  Pass a build asset (`/_app/...`) through from the renderer.

  The HTML the renderer sends names content-hashed chunks, and two
  builds of the same commit do not agree on those names — the entry
  chunks carry the build's version stamp. So the chunks must come from
  the same build as the HTML, which means from the same container.
  Unlike `render/1`, the renderer's cache headers are kept: adapter-node
  marks `immutable/` as cache-forever, and it is.
  """
  @spec proxy(Plug.Conn.t()) :: Plug.Conn.t()
  def proxy(conn) do
    target = url() <> conn.request_path <> query(conn)

    case Req.get(target,
           headers: forward_headers(conn),
           finch: SukhiFedi.Finch,
           retry: false,
           redirect: false,
           decode_body: false,
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: status, body: body} = resp} ->
        conn
        |> put_resp_content_type(content_type(resp))
        |> copy_header(resp, "cache-control")
        |> put_resp_header("x-static-source", "ssr")
        |> send_resp(status, body)

      {:error, reason} ->
        Logger.warning("ssr: renderer unreachable for asset: #{inspect(reason)}")
        send_resp(conn, 503, "")
    end
  end

  defp copy_header(conn, resp, name) do
    case Req.Response.get_header(resp, name) do
      [v | _] -> put_resp_header(conn, name, v)
      [] -> conn
    end
  end

  defp query(%Plug.Conn{query_string: ""}), do: ""
  defp query(%Plug.Conn{query_string: q}), do: "?" <> q

  defp content_type(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "content-type") do
      [ct | _] -> ct
      [] -> "text/html; charset=utf-8"
    end
  end

  # SvelteKit answers a redirect() with 3xx + Location; keep it.
  defp maybe_location(conn, resp) do
    case Req.Response.get_header(resp, "location") do
      [loc | _] -> put_resp_header(conn, "location", loc)
      [] -> conn
    end
  end

  defp unavailable do
    ~s|<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>ナタデコ</title><body style="font-family:sans-serif;padding:3rem 1.5rem;line-height:1.8"><p>いま、頁を描く手が休んでいます。すこししてから、もういちど開いてみてください。</p></body></html>|
  end
end
