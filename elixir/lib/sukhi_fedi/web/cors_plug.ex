# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.CorsPlug do
  @moduledoc """
  Permissive CORS so browser-based Mastodon clients (Elk, Phanpy, …) can
  call the API cross-origin.

  Those clients run on their own origin (e.g. `main.elk.zone`) and hit us
  with XHR/fetch, so the browser fires a preflight `OPTIONS` first and
  blocks the real request unless we answer it with `Access-Control-*`
  headers. Without this every third-party web client fails right after
  the OAuth token exchange — the preflight on `verify_credentials` /
  `timelines/home` 404s and the login looks broken.

  They authenticate with a Bearer token, not cookies, so
  `Access-Control-Allow-Origin: *` is both correct and safe — it's what
  Mastodon itself sends, and `*` makes browsers refuse credentialed
  (cookie) cross-origin requests, so the gateway's own cookie session
  can't be ridden from another origin.

  Preflight is answered here (204) before routing so it never falls
  through to a 404; for every other request the headers are attached via
  `register_before_send/2`, so they land regardless of which handler
  (incl. the plugin-node forwarder) sends the response.
  """
  import Plug.Conn

  @allow_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  @default_allow_headers "authorization, content-type, idempotency-key, x-queue-ticket"
  @expose_headers "link, x-ratelimit-limit, x-ratelimit-remaining, x-ratelimit-reset, x-queue-ticket, retry-after"

  # Defence-in-depth response headers, attached to every response.
  #
  # The CSP deliberately omits `script-src`/`default-src`: the SPA is a
  # SvelteKit (adapter-static) bundle whose hydration relies on an inline
  # bootstrap script, and a global `script-src 'self'` header would block
  # it. The XSS root cause is closed by sanitising note/bio HTML on
  # ingest (`SukhiFedi.HTML`); these directives add clickjacking,
  # base-tag, plugin and form-hijack protection without touching scripts.
  # (The `/uploads/*` media proxy layers a stricter `default-src 'none';
  # sandbox` on top of this — see Router.proxy_from_s3.)
  @csp "object-src 'none'; base-uri 'none'; frame-ancestors 'self'; form-action 'self'"
  @security_headers [
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "SAMEORIGIN"},
    {"referrer-policy", "strict-origin-when-cross-origin"},
    {"content-security-policy", @csp},
    {"strict-transport-security", "max-age=63072000; includeSubDomains"}
  ]

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> cors_headers()
    |> put_resp_header("access-control-allow-methods", @allow_methods)
    |> put_resp_header("access-control-allow-headers", requested_headers(conn))
    |> put_resp_header("access-control-max-age", "86400")
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts) do
    register_before_send(conn, &cors_headers/1)
  end

  defp cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-expose-headers", @expose_headers)
    |> security_headers()
  end

  # Only set a security header the handler hasn't already set, so the
  # `/uploads/*` media response can override `content-security-policy`
  # with its stricter sandbox policy.
  defp security_headers(conn) do
    Enum.reduce(@security_headers, conn, fn {k, v}, acc ->
      case get_resp_header(acc, k) do
        [] -> put_resp_header(acc, k, v)
        _ -> acc
      end
    end)
  end

  # Echo the browser's requested headers when it sends them (some clients
  # add custom ones); fall back to the common set otherwise.
  defp requested_headers(conn) do
    case get_req_header(conn, "access-control-request-headers") do
      [h | _] when is_binary(h) and h != "" -> h
      _ -> @default_allow_headers
    end
  end
end
