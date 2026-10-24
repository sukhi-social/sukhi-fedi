<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: WebFinger and host-meta

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Schema: `schemas/webfinger-jrd.schema.json`

## In one paragraph

To find a Misskey user from `user@host`, a server asks WebFinger. Misskey does the same when it looks for a sukhi user: it lowercases the name, asks sukhi, takes the first `self` link, and then checks that the actor URL is on the same host. sukhi answers in the shape Misskey needs.

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

## What sukhi does **[sukhi]** `web/webfinger_controller.ex`

| Misskey asks | sukhi answers |
| --- | --- |
| `acct:name@domain` for a local account | 200 JRD: `subject`, `aliases` (the actor URL), `self`, `profile-page` |
| a name on another host | 404 (Misskey itself answers 422) |
| an actor URL under `/users/<name>` | the same JRD |
| no `resource` | 400 |
| `host-meta` | XRD with the `lrdd` template |

A typical sukhi answer ([webfinger-jrd schema](../schemas/webfinger-jrd.schema.json)):
```json
{
  "subject": "acct:hina@sukhi.social",
  "aliases": ["https://sukhi.social/users/hina"],
  "links": [
    {
      "rel": "self",
      "type": "application/activity+json",
      "href": "https://sukhi.social/users/hina"
    },
    {
      "rel": "http://webfinger.net/rel/profile-page",
      "type": "text/html",
      "href": "https://sukhi.social/@hina"
    }
  ]
}
```

The schema, copied here so the page can be read on its own:

<!-- schema: webfinger-jrd.schema.json -->
```json
{
  "$schema": "http://json-schema.org/draft-04/schema#",
  "id": "https://sukhi.social/spec/schemas/webfinger-jrd.schema.json",
  "$comment": "SPDX-License-Identifier: AGPL-3.0-or-later",
  "title": "WebFinger answer (JRD)",
  "description": "Descriptive of what Misskey's resolver needs and what sukhi answers: `subject` as `acct:`, and a `self` link of type `application/activity+json`. Misskey takes the first `self` link and does not check its type (see misskey/webfinger.md); sukhi sets it anyway.",
  "type": "object",
  "required": [
    "subject",
    "links"
  ],
  "properties": {
    "subject": {
      "type": "string",
      "pattern": "^acct:[^@\\s]+@[^@\\s]+$"
    },
    "aliases": {
      "type": "array",
      "items": {
        "type": "string",
        "format": "uri"
      }
    },
    "links": {
      "type": "array",
      "minItems": 1,
      "items": [
        {
          "type": "object",
          "required": [
            "rel",
            "href"
          ],
          "properties": {
            "rel": {
              "enum": [
                "self"
              ]
            },
            "type": {
              "enum": [
                "application/activity+json"
              ]
            },
            "href": {
              "type": "string",
              "format": "uri"
            }
          }
        }
      ],
      "additionalItems": {
        "type": "object",
        "required": [
          "rel"
        ],
        "properties": {
          "rel": {
            "type": "string"
          },
          "type": {
            "type": "string"
          },
          "href": {
            "type": "string",
            "format": "uri"
          },
          "template": {
            "type": "string"
          }
        }
      }
    }
  }
}
```

## Things to watch

- sukhi puts the `self` link first, which is the one Misskey uses.
- Misskey lowercases the user name before asking. sukhi passes the name to `Accounts.get_account_by_username/1` as it is. Whether that lookup ignores case was **[not seen]**. If it does not, an account with capitals in its name cannot be found by Misskey. This needs a test.
- sukhi caches each answer for 600 seconds.
