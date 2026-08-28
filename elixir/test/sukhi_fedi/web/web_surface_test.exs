# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.WebSurfaceTest do
  use ExUnit.Case, async: true

  # This file exists because `/metrics` was open for months and nobody
  # decided that — it was the default, and defaults don't get revisited.
  # It carried no personal data, but it handed anyone the exact version
  # of every dependency, the internal database host and name, and every
  # table name.
  #
  # So: every door in the router is listed below, on one of two lists.
  # Adding a route makes this test fail until you put it on one, which
  # is the whole point — the question "may this be reached from the
  # internet?" gets asked once, by a person, at the time the door is cut.
  #
  # It is a yes/no about *reachability from the edge*, not about who is
  # authorised once they arrive. Most `@edge` routes still want a session
  # or a bearer; that lives with the route. This list only answers "is
  # this meant to be answerable from outside at all".

  @router Path.join(__DIR__, "../../../lib/sukhi_fedi/web/router.ex")

  # Meant to be reachable from the internet.
  @edge [
    # ── User-facing login (session_token cookie minter)
    "get /login",
    "post /login",
    "post /login/totp",
    "post /login/email/request",
    "post /login/email",
    "post /login/passkey/options",
    "post /login/passkey",
    "post /logout",
    "post /signup/email/request",
    "post /signup/email/confirm",
    "post /signup/session",

    # ── Legal pages (static HTML baked at compile time)
    "get /privacy",
    "get /terms",

    # ── Password set / change / remove (session_token cookie required)
    "get /settings/password",
    "post /settings/password",
    "post /settings/password/remove",

    # ── Login-factor management (cookie-gated; see SecurityController)
    "get /auth/state",
    "get /settings/security",
    "post /settings/reauth/request",
    "post /settings/email/request",
    "post /settings/email/confirm",
    "post /settings/totp/setup",
    "post /settings/totp/enable",
    "post /settings/totp/disable",
    "post /settings/passkeys/options",
    "post /settings/passkeys",
    "post /settings/passkeys/:id/delete",
    "get /settings/sessions",
    "post /settings/sessions/:id/revoke",

    # ── Self-cleanup (archive own old posts; cookie-gated, reauth on execute)
    "get /settings/cleanup",
    "post /settings/cleanup/preview",
    "post /settings/cleanup/execute",

    # ── Static assets for the SPA + login page
    "get /static/*path",

    # ── ActivityPub / well-known (handled natively by Elixir)
    "get /.well-known/webfinger",
    "get /.well-known/host-meta",
    "get /users/:name",
    "get /users/:name/featured",
    "get /users/:name/followers",
    "get /users/:name/following",
    "get /users/:name/invites/:code",
    "get /users/:name/pendingFollowers",
    "get /users/:name/pendingFollowing",
    "get /users/:name/outbox",
    "get /users/:name/notes/:note_id",
    "get /users/:name/notes/:note_id/replies",
    "get /users/:name/quote-auth/:id",
    "post /users/:name/inbox",
    "post /inbox",

    # ── NodeInfo (Elixir-native)
    "get /.well-known/nodeinfo",
    "get /nodeinfo/2.0",
    "get /nodeinfo/2.1",

    # ── Uploaded media
    "get /uploads/*path",

    # ── Remote media proxy
    "get /proxy/media/:id",
    "get /proxy/avatar/:id",
    "get /proxy/header/:id",

    # ── Human-facing HTML + JSON proxy for nodeinfo lookup
    "get /",
    "get /signup",
    "get /invite/:code",
    "get /timeline",
    "get /app/callback",
    "get /settings",
    "get /search",
    "get /messages",
    "get /messages/:id",
    "get /clips",
    "get /compose",
    "get /notifications",
    "get /bookmarks",
    "get /favourites",
    "get /requests",
    "get /lists",
    "get /lists/:id",
    "get /tags/:tag",
    "get /map",
    "get /check",
    "get /_app/*path",
    "get /twemoji/*path",
    "get /favicon.ico",
    "get /favicon.png",
    "get /apple-touch-icon.png",
    "get /icon-512.png",
    "get /icon-192.png",
    "get /icon-maskable-512.png",
    "get /manifest.webmanifest",
    "get /hinata.png",
    "get /hinata-signup.png",
    "get /service-worker.js",
    "get /posts/:id",
    "get /d/:slug/new",
    "get /d/:slug",
    "get /hello",
    "get /tomo",
    "get /people/:id",
    "get /veranda",
    "get /about",
    "get /api/nodeinfo",
    "get /api/watchers",
    "post /api/watchers",
    "get /api/stats/stream",

    # ── Health
    # `/up` says only "the BEAM answers". Deliberately no version, no
    # counts — a load balancer needs one bit, and one bit is all it gets.
    "get /up",

    # ── Mastodon/Misskey REST API — dispatched to plugin nodes
    "get /api/v1/streaming",
    "get /api/v1/streaming/user",
    "get /api/v1/streaming/user/notification",
    "get /api/wt",
    "get /api/map",
    "match /api/v1/*_",
    "match /api/admin/*_",
    "match /api/v2/*_",
    "match /oauth/*_"
  ]

  # Must not answer a stranger. Each one says why, and how it is held shut.
  @closed [
    # PromEx scrape output. No personal data, but it names every
    # dependency and its version, the internal db host and name, every
    # table, and the shape of the load. Behind the `:metrics_token`
    # bearer; 404 when no token is configured, so a fresh operator is
    # closed by default rather than open by default.
    "get /metrics",

    # The JSON shape of the same telemetry (live snapshot + stored
    # history). Same bearer, same 404-when-unconfigured.
    "get /api/metrics"
  ]

  test "every route in the router is declared, on exactly one list" do
    declared = @edge ++ @closed
    actual = routes()

    duplicates = declared -- Enum.uniq(declared)
    assert duplicates == [], "declared twice: #{inspect(duplicates)}"

    undeclared = actual -- declared
    stale = declared -- actual

    assert undeclared == [],
           """
           New doors in the router that nobody has decided about:

           #{Enum.map_join(undeclared, "\n", &"    #{&1}")}

           May each of these be reached from the internet? Put it on
           @edge if yes, on @closed (with a note saying how it is held
           shut) if no. Answering here is the point of this test.
           """

    assert stale == [],
           """
           Declared here but no longer in the router:

           #{Enum.map_join(stale, "\n", &"    #{&1}")}

           If the route is gone, drop the line.
           """
  end

  # Routes are read from the source rather than from Plug.Router, which
  # compiles them into `do_match/4` clauses and keeps no table to ask.
  defp routes do
    @router
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^  (get|post|put|patch|delete|match|options) "([^"]*)"/, line) do
        [_, method, path] -> ["#{method} #{path}"]
        nil -> []
      end
    end)
  end
end
