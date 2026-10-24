<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: WebFinger and host-meta

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Type: `#WebFingerAnswer`, defined below

## In one paragraph

To find a Misskey user from `user@host`, a server asks WebFinger. As a client, Misskey lowercases the name, asks the other server, takes the first `self` link, and then checks that the actor URL is on the same host.

## Misskey as a server **[src]** `server/WellKnownServerService.ts`

| Route | What it does |
| --- | --- |
| `GET /.well-known/webfinger` | See below. |
| `GET /.well-known/host-meta` | XRD with one `Link rel="lrdd" type="application/xrd+xml"`, whose template is `/.well-known/webfinger?resource={uri}`. |
| `GET /.well-known/host-meta.json` | The same link as JSON, `type` `application/jrd+json`. |
| `GET /.well-known/nodeinfo` | `{ "links": [...] }` from the NodeInfo service. |
| `OPTIONS /.well-known/*` | 204. |

The routes host-meta, nodeinfo, and webfinger answer 403 when federation is `none`. CORS allows any origin for `GET` and `OPTIONS`.

The WebFinger query:
- `resource` is required. If it is not a string: 400.
- The value is lowercased before it is read.
- Accepted: a local actor URL (`<url>/users/<id>`), a local profile URL (`<url>/@<name>`), an `acct:` URI, or a bare `user@host`.
- A host that is not the local host: 422. No local, unsuspended user: 404.
- No `rel` filter is read. Remote actor URLs are not resolved.

The WebFinger answer:
- `subject` is `acct:<username>@<host>`.
- Links: `self` (`application/activity+json`), `http://webfinger.net/rel/profile-page` (`text/html`), and `http://ostatus.org/schema/1.0/subscribe` with a `template`. There are no `aliases`.
- JRD or XRD is chosen from the `Accept` header; anything else gets JRD. `Cache-Control: public, max-age=180`.

## Misskey as a client **[src]** `core/RemoteUserResolveService.ts`

1. The user name is lowercased and the host is converted to punycode. For the local host WebFinger is not used.
2. The first link whose `rel` is `self` is used (compared in lowercase). Its `type` is not checked. Without one, resolution fails with `self link not found`.
3. A new user is created from the actor fetched at `self.href`. There is no host check on this path in this file.
4. For a known user whose stored URI differs from `self.href`, the new URI's host must equal the host being resolved, or resolution fails with `Invalid uri`. The stored URI is then replaced.
5. A user not fetched for 24 hours is fetched again.

How the request URL is built, the `host-meta` fallback, any check of the returned `subject`, and redirects belong to `WebfingerService`, which was **[not seen]**.

## An example

An answer Misskey accepts (type `#WebFingerAnswer`):
```json
{
  "subject": "acct:hina@other.example",
  "aliases": ["https://other.example/users/hina"],
  "links": [
    {
      "rel": "http://webfinger.net/rel/profile-page",
      "type": "text/html",
      "href": "https://other.example/@hina"
    },
    {
      "rel": "self",
      "type": "application/activity+json",
      "href": "https://other.example/users/hina"
    }
  ]
}
```

The type, in [CUE](https://cuelang.org):

```cue
// What Misskey's resolver needs from a WebFinger answer: a `subject` and a
// `self` link. It uses the first `self` link, and does not check its `type`.
#WebFingerAnswer: {
	subject:  =~"^acct:[^@\\s]+@[^@\\s]+$"
	aliases?: [...#URL]
	links: [...#Link] // one of them has rel "self"; CUE cannot say "one of" here
	...
}

#Link: {
	rel:       string
	type?:     string
	href?:     #URL
	template?: string
	...
}
```

## Things to watch

- Misskey lowercases the user name before asking. A server that compares names with case sensitivity will not find an account that has capitals in its name.
- Misskey checks the host of the `self` link only for a user it already knows.
