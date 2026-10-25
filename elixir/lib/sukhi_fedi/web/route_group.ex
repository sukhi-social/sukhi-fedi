# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.RouteGroup do
  @moduledoc """
  Names the kind of request a `Plug.Conn` is, for metrics — a handful of
  groups, never the raw path (a label per path would be unbounded).

  The groups are the ones the load test (`scripts/load/`) found to cost
  differently, so a table of "p95 by group" says which kind of request
  gets slow first:

    * `shell`           — a browser GET of an SPA page (never rate limited)
    * `static`          — files served as-is
    * `timeline_public` — same answer for everyone, the cacheable one
    * `timeline_home`   — per user, joins the follow graph
    * `timeline_other`
    * `api`             — the rest of the Mastodon/plugin API and OAuth
    * `auth`            — login, signup, logout
    * `federation`      — inbox, WebFinger, nodeinfo, actor documents
    * `other`
  """

  alias SukhiFedi.Web.SpaRoutes

  @static ["/static/", "/_app/", "/twemoji/"]

  @spec of(Plug.Conn.t()) :: String.t()
  def of(%Plug.Conn{request_path: path} = conn) do
    cond do
      Enum.any?(@static, &String.starts_with?(path, &1)) -> "static"
      path == "/api/v1/timelines/public" -> "timeline_public"
      path == "/api/v1/timelines/home" -> "timeline_home"
      String.starts_with?(path, "/api/v1/timelines/") -> "timeline_other"
      String.starts_with?(path, ["/api/", "/oauth/"]) -> "api"
      String.starts_with?(path, ["/login", "/signup", "/logout"]) -> "auth"
      federation?(path) -> "federation"
      SpaRoutes.page_request?(conn) -> "shell"
      true -> "other"
    end
  end

  defp federation?(path) do
    path in ["/inbox", "/.well-known", "/nodeinfo"] or
      String.starts_with?(path, ["/inbox/", "/users/", "/.well-known/", "/nodeinfo/"])
  end

  @doc "Status as a label: the exact code for the ones that mean 'busy', else its class."
  @spec status_label(integer()) :: String.t()
  def status_label(s) when s in [429, 503, 504], do: Integer.to_string(s)
  def status_label(s) when s >= 100 and s < 600, do: "#{div(s, 100)}xx"
  def status_label(_), do: "other"
end
