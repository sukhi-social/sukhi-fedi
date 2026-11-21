# 外に開いている口 — a door list, and how it stays honest

`/metrics` was reachable from the internet for months. Nobody decided
that. It was the default, and defaults are the things nobody revisits.

It carried nothing personal — no accounts, no addresses, no post
content, not even a request path. But it named every dependency and its
exact version, the internal database host and name, every table in the
schema, and the shape of the load. None of that breaks anything on its
own. All of it is homework that someone looking for a known
vulnerability would otherwise have to do themselves.

So we wrote down the doors.

## The list

`elixir/test/sukhi_fedi/web/web_surface_test.exs` holds every route in
`SukhiFedi.Web.Router`, on one of two lists:

- **`@edge`** — meant to be answerable from the internet.
- **`@closed`** — must not answer a stranger. Each entry says why, and
  how it is held shut.

The test reads the routes out of the router source and compares. Add a
route and the test fails until you put it on a list. That failure is the
whole mechanism: it asks one question, at the moment the door is cut, of
the person cutting it.

> May this be reached from the internet?

It is deliberately a yes/no about **reachability**, not about
authorisation. Most `@edge` routes still want a session cookie or a
bearer — that check lives with the route, where it belongs. This list
answers only whether the door is meant to face the street at all,
because that is the question that goes unasked.

## A web front's pages are not doors of their own

`/signup`, `/lists/:id` and the rest of the pages people read have no line in
`router.ex`: the gateway has no pages of its own to list. They belong to a
web front (`web-next`, or `web-natadeco` as `web-board`), and the front
decides what its own pages answer.

Where the gateway sits in front, the catch-all `get /*path` asks the front
that the instance config's routes name for that path (`SukhiFedi.Web.Upstreams`)
and forwards it, GET only. A path nothing claims is a `404` — except
`/@name`, where the gateway gives a crawler the public preview. A path that
starts with a dot is never forwarded. Add a page to a front and it exists;
there is no second list in the gateway to forget.

What the gateway does keep, as its own lines (and so its own entries here):
the legal pages, `/map`, the setup page, `/admin`, and every route that is
not a page — federation, `/api`, `/oauth/token`, `/oauth/revoke`.

## Why the test and not a plug

A plug that denied anything undeclared would be the stronger guarantee,
and one day it might be worth it. But this server federates: a path
missed in a default-deny list is a silent break in someone else's
timeline, discovered days later. A failing test costs a minute and
breaks nobody. Start where the cost of being wrong is smallest.

The router is a `Plug.Router`, which compiles its routes into
`do_match/4` clauses and keeps no table to ask at runtime — so the test
reads the source. Slightly crude; honest about being so.

## Belt and braces

In front of `sukhi.f3liz.casa` sits [Anubis](anubis.ja.md), whose policy
also denies `/metrics` at the edge. That is a second layer, not the
first one. The app is the layer that knows what it is serving, so the
app is where the decision lives — and it is the layer that travels with
the code to every other instance running it.

## Closed today

| Route | Held shut by |
|---|---|
| `GET /metrics` | `METRICS_TOKEN` bearer; `404` when unset |
| `GET /api/metrics` | the same bearer, the same `404` |

`404` rather than `401` when no token is configured, so a fresh operator
who has not thought about telemetry yet is closed rather than open. See
[`ENV.md`](ENV.md).
