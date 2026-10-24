<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Transport

- Part of [the Misskey specification](README.md); source tags and terms are explained there.

## In one paragraph

Misskey takes activities by `POST` to an inbox, checks the form of the request, answers 202 at once, and checks the signature later in a queue. So a 202 means "well-formed and queued", not "accepted". It serves objects by `GET` to anyone who asks for ActivityPub JSON, with no signature check.

## Receiving: `POST /inbox` and `POST /users/:user/inbox`

**[src]** `server/ActivityPubServerService.ts`. Both routes run the same code, so `/users/:user/inbox` is not checked against `:user`: it is the shared inbox under another name. The checks run in this order, and the first failure answers:

| # | Check | Answer |
| --- | --- | --- |
| 1 | The body is larger than 64 KB | 413 (Fastify's own answer; Misskey sets the limit but not the code) |
| 2 | `Content-Type` is not `application/activity+json` or `application/ld+json` | 415 |
| 3 | The body is empty or not JSON | 400 |
| 4 | Federation is set to `none` | 403 |
| 5 | The `Signature` header cannot be parsed, or does not sign `(request-target)`, `host`, and `date` | 401 |
| 6 | `host` is not among the signed headers, or the `Host` header is not Misskey's own host | 401 |
| 7 | `digest` is not among the signed headers, the `Digest` header is missing or malformed, its algorithm is not SHA-256, or it does not match the body | 401 |
| 8 | The body has no `actor` | 400 |
| otherwise | The activity and the parsed signature are queued | 202 |

Rows 1 to 3 are done by the web framework before Misskey's own code runs; their order among themselves was not read. The signature itself is not verified here; see [signatures](signatures.md). The queue gives up on a failed activity without telling the sender.

## Serving: `GET`

**[src]** same file.

- A route that serves an object answers ActivityPub JSON when the `Accept` header prefers `application/activity+json` or `application/ld+json` over HTML, and the web page otherwise. The reply has `Vary: Accept`, the content type `application/activity+json; charset=utf-8` (or the `ld+json` profile type when asked), and `Cache-Control: public, max-age=180`.
- No signature is checked on any `GET` in this file. Federation `none` answers 403.
- Which URLs exist, and what they return:

| URL | Returns | Answers other than 200 |
| --- | --- | --- |
| `/users/:id`, `/@:name` | the actor ([objects](objects.md): `#Person`) | 404 unknown; a remote user's URL redirects (301) to their own |
| `/notes/:id` | the note (`#Note`) | 404 unless the note is public or home and not local-only; a remote note redirects to its own URI |
| `/notes/:id/activity` | the `Create` or `Announce` for the note | 404, same rule |
| `/users/:id/outbox`, `followers`, `following`, `collections/featured` | collections ([collections](collections.md)) | |
| `/users/:id/publickey` | the key (`#Key`) | |
| `/emojis/:name` | an emoji tag (`#Emoji`) | 404 |
| `/likes/:id` | a `Like` | 404 |
| `/follows/:follower/:followee`, `/follows/:requestId` | a `Follow` (the id Misskey puts on a follow it sent) | 404 |
| `/blocks/:id`, `/moves/...` | not served in this file | |

## Things to watch

- A body larger than 64 KB is refused, and a resend of the same body is refused again.
- A `Follow` that Misskey sent can be fetched from its own id, so an `Accept` that carries only that id can be resolved.
