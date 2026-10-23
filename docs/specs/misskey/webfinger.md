<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: WebFinger and host-meta

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

### Misskey as a server **[src]** `server/WellKnownServerService.ts`

| Route | Behaviour |
| --- | --- |
| `GET /.well-known/webfinger` | See below. |
| `GET /.well-known/host-meta` | XRD with one `Link rel="lrdd" type="application/xrd+xml"` whose template is `/.well-known/webfinger?resource={uri}`. |
| `GET /.well-known/host-meta.json` | The same link as JSON, `type` `application/jrd+json`. |
| `GET /.well-known/nodeinfo` | `{ "links": [...] }` from the NodeInfo service. |
| `OPTIONS /.well-known/*` | 204. |

- The three routes host-meta, nodeinfo, and webfinger answer 403 when federation is `none`.
- CORS: `Access-Control-Allow-Origin: *`, methods `GET, OPTIONS`.

WebFinger query:
- `resource` is required. If it is not a string: 400.
- The value is lowercased before it is parsed.
- Accepted forms: a local actor URL (`<url>/users/<id>`), a local profile URL (`<url>/@<name>`), an `acct:` URI, and a bare `user@host`.
- A host that is not the local host: 422. No local, unsuspended user: 404.
- No `rel` filter is read. Remote actor URLs are not resolved.

WebFinger answer:
- `subject`: `acct:<username>@<host>`.
- Links: `self` with type `application/activity+json`; `http://webfinger.net/rel/profile-page` with type `text/html`; `http://ostatus.org/schema/1.0/subscribe` with a `template` (no type).
- No `aliases`.
- JRD or XRD is chosen from the `Accept` header. Anything else gets JRD. `Vary: Accept` and `Cache-Control: public, max-age=180`.

### Misskey as a client **[src]** `core/RemoteUserResolveService.ts`

- The username is lowercased and the host is converted to punycode. For the local host, WebFinger is not used.
- The first link whose `rel` is `self` (compared lowercase) is used. Its `type` is not checked. If there is none, resolution fails with `self link not found`.
- For a new user, the actor is fetched from `self.href`. There is no host check on this path in this file.
- For a known user whose stored URI differs from `self.href`, the host of the new URI must equal the host being resolved. Otherwise `Invalid uri`. The stored URI is then replaced.
- A user not fetched for 24 hours is fetched again.
- How the request URL is built, the `host-meta` fallback, any check of the returned `subject`, and redirects are in `WebfingerService`, which was **[not seen]**.

### sukhi **[sukhi]** `web/webfinger_controller.ex`

| Misskey asks | sukhi answers |
| --- | --- |
| `acct:name@domain` for a local account | 200 JRD with `subject`, `aliases` (the actor URL), `self` (`application/activity+json`), `profile-page` (`text/html`). `application/jrd+json`. |
| a name for another host | 404 (Misskey itself answers 422) |
| an actor URL under `/users/<name>` | the same JRD |
| no `resource` | 400 |
| `host-meta` | XRD with the `lrdd` template |

- sukhi puts the `self` link first, so Misskey's "first `self`" rule finds it.
- Misskey lowercases the user name before asking. sukhi passes the name to `Accounts.get_account_by_username/1` as given. Whether that lookup ignores case was **[not seen]**. If it does not, and an account has capitals in its name, Misskey cannot find it. This needs a test.
- sukhi caches each answer for 600 seconds.
