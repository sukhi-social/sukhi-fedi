<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Specifications: implemented, and written by sukhi

Two lists. First, every external specification the code implements, with how far. Second, the specifications sukhi wrote itself, for behaviour that no existing specification expresses.

- Date of survey: 2026-10-23, from the repository at the commit that adds this file.
- Evidence rule: a row says "yes" only if code or a route exists. Rows I did not trace into code say so.
- Companion: [`../FEDERATION.md`](../FEDERATION.md) (FEP-67ff self-description, pinned to `file:line`).

## Status words

| Word | Meaning |
| --- | --- |
| both | Sent and received. |
| emit | Sent only. Received data is ignored or tolerated. |
| read | Received only. |
| partial | Some of the specification; the gap is named. |
| doc | A document only; no code. |

## 1. External specifications in the code

### Federation

| Specification | Status | Evidence |
| --- | --- | --- |
| ActivityPub, ActivityStreams 2.0 | both | `fedi/builders.ex`, `fedi/inbox.ex` |
| WebFinger (RFC 7033) | both | `web/webfinger_controller.ex`, `federation/webfinger.ex` |
| host-meta (RFC 6415) | emit | `web/webfinger_controller.ex:151`, `web/router.ex:290` |
| NodeInfo 2.0, 2.1 | emit | `web/nodeinfo_controller.ex` (`metadata` is empty) |
| NodeInfo of other servers | read | `addons/nodeinfo_monitor/` |
| HTTP signatures, draft-cavage-12 | both | `fedi/http_signature.ex` |
| HTTP Message Signatures (RFC 9421) | both | `fedi/http_signature.ex`, `delivery/.../sig_spec.ex` |
| RsaSignature2017 Linked-Data signature | emit | `fedi/ld_signature.ex` (inbound verify is test-only) |
| JSON Canonicalization (RFC 8785), RDFC-1.0 | both | `fedi/canon.ex` |
| FEP-8b32 Object Integrity Proofs (`eddsa-jcs-2022`) | both | `fedi/oip.ex` |
| FEP-521a actor public keys (`assertionMethod`) | emit; read for FEP-8b32 keys only | `shared/.../actor_json.ex:136`, `fedi/oip.ex:174` |
| FEP-8fcf followers synchronization | both | `delivery/.../followers_sync.ex` |
| FEP-e232 Object Links (quotes) | both | `fedi/builders.ex:347`, `ap/instructions/extract.ex:46` |
| FEP-044f consent-respecting quotes | partial | `QuoteAuthorization` route `/users/:name/quote-auth/:id` exists; `quote` is not emitted and `QuoteRequest` is not handled (`FEDERATION.md` §11) |
| FEP-5feb search-indexing consent | emit | `shared/.../actor_json.ex:69` (`discoverable`, `indexable`) |
| FEP-4ccd pending followers/following | emit | `actor_json.ex:90`, routes `/users/:name/pendingFollowers`, `/pendingFollowing` |
| FEP-bebd follow invites | yes (not traced in depth) | `schema/follow_invite.ex`, route `/users/:name/invites/:code` |
| FEP-7458 replies collection | emit | route `/users/:name/notes/:note_id/replies` |
| FEP-8967 link previews | stored per note; federation direction not traced | `schema/preview_card.ex` |
| FEP-7888 `context` | read | `addons/deco/federation.ex:41` |
| FEP-1b12 group federation | partial; the `audience` of boards | `notes/create.ex:95`, `addons/deco/` |
| FEP-67ff FEDERATION.md | doc | `../FEDERATION.md` |
| Mastodon `Move`, `alsoKnownAs`, `movedTo` | both | `actor_json.ex` |
| Mastodon profile `PropertyValue`, `Emoji` tags | both | `actor_json.ex` |
| Misskey `_misskey_content`, `_misskey_quote`, emoji reaction as `Like` | both | `fedi/builders.ex:206-364` |
| Misskey avatar decorations | read, outside ActivityPub | `FEDERATION.md` (last section) |
| GoToSocial JSON-LD context | read (vendored) | `fedi/canon.ex:73` |

### Client API, accounts, delivery to browsers

| Specification | Status | Evidence |
| --- | --- | --- |
| Mastodon REST API | partial; gaps listed | [`../MASTODON_API.md`](../MASTODON_API.md) |
| Misskey API | doc; not implemented | [`../MISSKEY_API.md`](../MISSKEY_API.md) |
| OAuth 2.0 (RFC 6749), token revocation (RFC 7009) | yes | `oauth.ex`, `api/.../capabilities/oauth.ex` |
| TOTP (RFC 6238), HOTP (RFC 4226) | yes | `auth/totp.ex` |
| Cookies (RFC 6265) | yes | `web/auth/session_cookie.ex` |
| Web Push (RFC 8030), VAPID (RFC 8292) | yes | `addons/web_push.ex`, `delivery/.../push/worker.ex`, `config/runtime.exs:188` |
| Web Push encryption (RFC 8291, RFC 8188) | yes (cited in `WEBPUSH.md` and delivery code) | `delivery/test/push/encryption_round_trip_test.exs` |
| JWK (RFC 7517) | yes | `addons/nodeinfo_monitor/key_gen.ex`, `fedi/jwk.ex` |

### Discrepancy found

`FEDERATION.md` §11 says `manuallyApprovesFollowers` is not gated. The code now has locked-account pieces (`pendingFollowers` routes, `follow_invite`). One of the two is stale. I did not trace which.

## 2. Specifications written by sukhi

Each one covers behaviour that is observable from outside and that no listed standard states. Each says which standard it builds on.

### Requirement words

These specifications are written so that others can copy them.

- **MUST** only where an implementation that skips the rule cannot talk to others, or loses data, or opens a security hole.
- **SHOULD** where the rule helps others (reach, load, tidiness) but a copy that skips it still works.
- **MAY** for choices of one implementation, such as a number taken from sukhi's tuning.

| Id | Title | Builds on | Status |
| --- | --- | --- | --- |
| [sukhi-0001](sukhi-0001-signature-fallback.md) | Signature scheme fallback and per-host memory | RFC 9421, draft-cavage-12 | Draft; implemented |
| [sukhi-0002](sukhi-0002-follower-sync-guard.md) | Safe reconciliation of followers collections | FEP-8fcf | Draft; implemented |
| [sukhi-0003](sukhi-0003-legacy-quote-profile.md) | Quote compatibility profile | FEP-e232, FEP-044f | Draft; implemented |
| [sukhi-0004](sukhi-0004-signer-binding.md) | Binding the signer to the claimed actor | RFC 9421, ActivityPub | Draft; implemented |

Not a specification: [`../spec-declaration-notes.md`](../spec-declaration-notes.md) is a design note on how a server could declare which of these (and which FEPs) it implements, using FEP-844e. Nothing in it is implemented.

## 3. Descriptive specifications

These say what another server does. They bind nobody.

| Document | Subject |
| --- | --- |
| [misskey/](misskey/README.md) | How Misskey behaves on the wire, one file per feature, with sukhi's matching actions |

Open decision: the identifier base. The specifications use `https://sukhi.social/spec/<id>/<version>` as a provisional identifier. The real domain and a permanent path need to be chosen first.
