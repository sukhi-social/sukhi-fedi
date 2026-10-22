# Federation behaviour (self-description)

> An honest, FEP-67ff-style self-description of how this server speaks
> ActivityPub. Written from the **live Elixir code** (`SukhiFedi.Fedi.*`
> and the delivery node), not from intentions. Every claim below pins
> the function that backs it; if a row says we do something, there is
> code at that `file:line` doing it.
>
> The Bun/Fedify worker that [`FEDIFY.md`](FEDIFY.md) documents is
> **retired in production** (v0.3.0+); it survives only as the dev-stack
> oracle that mints golden fixtures. This file describes the path that
> actually runs. Companions: [`ARCHITECTURE.md`](ARCHITECTURE.md) (where
> processes run) and [`CODE_STYLE.md`](CODE_STYLE.md) (where concerns
> live — every property below sits in one named place, by §0/§3).

## 1. Protocol surface

| Aspect | Behaviour | Where |
| --- | --- | --- |
| Object/activity model | Mastodon-compatible AS2 + ActivityPub | `fedi/builders.ex` |
| Activity types emitted | `Create` (Note/vote/dm), `Follow`, `Accept`, `Announce`, `Like`, emoji-react-as-`Like`, `Undo`, `Delete`, `Add`, `Remove` | `builders.ex:56-67` |
| Activity types accepted | `Follow` (special reply shape) + `Announce Create Update Delete Like EmojiReact Undo Accept Reject Move Block Flag Add Remove`; anything else is `ignore`d | `fedi/inbox.ex:31-48` |
| `@context` (egress) | one shared context: AS2 + `security/v1` + `security/data-integrity/v1` + a small compatibility map (`toot:`, `misskey:`, `sensitive`, `Hashtag`, `Emoji`, `_misskey_content`, `_misskey_quote`, `quoteUrl`) | `builders.ex:32-49` |
| Transport idempotency | receive: `objects.ap_id` unique + `on_conflict: :nothing`; send: `delivery_receipts(activity_id, inbox_url)` unique, checked before every POST | `delivery/.../worker.ex:43,332-340` |

## 2. Audience / addressing

`as:Public` is emitted as the **full IRI**
`https://www.w3.org/ns/activitystreams#Public`, never the compact
`as:Public` or bare `Public` — receivers that gate visibility on the
exact string (iceshrimp, Mastodon) silently dropped activities that
were addressed with a shortened form, which is why every builder is
routed through the one audience module.

- **Single source for `to`/`cc`** — `Fedi.Audience` (`audience.ex`).
  `public/1`, `unlisted/1`, `followers_only/1`, `direct/1`, `mirror/1`
  are the only shapes; no builder hand-writes `to`/`cc`
  (`audience.ex:19-37`, used at `builders.ex:72,132,174,…`).
- **Public IRI constant** — `Audience.as_public/0` returns the full IRI
  (`audience.ex:12,17`).
- **Inbound tolerance** — on the way *in* we accept all three spellings
  (`@public_aliases = [full-IRI, "as:Public", "Public"]`), because a
  *fetched* object can keep the compact form even though inbox-delivered
  activities arrive expanded. Missing this once demoted fetched public
  posts to `direct` (`ap/instructions/extract.ex:10-16,148`,
  `public?/1`, `dm_addressing?/1`, `visibility_from/1`).

## 3. Authentication of inbound activities

Two gates, in this order, on every POST to an inbox. Both are
checked **once at the boundary**; nothing past the gate re-checks
(CODE_STYLE §2).

1. **HTTP Signature is required** — `FedifyClient.verify/1` runs
   *before* the body is parsed; a `%{"ok" => false}` (or any error)
   answers **401** and the activity never executes
   (`web/inbox_controller.ex:51-97`). The verifier resolves the `keyId`
   key, checks the signature, and on success reports *who* signed —
   `keyId` + the key's `owner` (`fedi/verifier.ex:34-66`).
2. **Signer is bound to the claimed actor** — the signer's host travels
   with the activity so `Instructions.trusted_inline_origin?/2` can
   refuse inline data whose claimed `actor` lives on a different host
   than the signer (`inbox_controller.ex:71,80`). Verifying bytes
   without this binding is what the 2026-06 audit found and closed.

Supporting behaviour:

- **Signature spec auto-detect** — a `Signature-Input` header means
  RFC 9421, otherwise draft-cavage-http-signatures-12; same module
  verifies both (`fedi/http_signature.ex:101-107`).
- **Digest must be covered** — a body-bearing request must have its
  `digest` (cavage) / `content-digest` (9421) *in the signed header
  set*, not merely present. fedify's 9421 path only checks the digest
  when the sender chose to sign it; we always insist, so a peer can't
  sign an uncontested header set and swap the body. Every real sender
  covers the digest, so the strictness costs no interop
  (`http_signature.ex:22-26,239-246,391-411`).
- **Clock window** — 3600 s (`http_signature.ex:34`).
- **Public-URL reconstruction** — the URL the remote signed against is
  rebuilt from our configured `:domain`, not the proxy-rewritten `Host`
  header (cloudflared/kamal rewrite it to an internal value)
  (`inbox_controller.ex:34,180-184`).
- **Authorized fetch** — when the inbox is user-scoped we hand the
  receiving account's key down so the remote-actor dereference is
  signed (Mastodon Secure Mode / Misskey auth-fetch peers return 401 to
  an unsigned actor fetch). Shared inbox has no key and falls back to
  unsigned (`inbox_controller.ex:191-205`, `fedi/fetcher.ex:5`).
- **Instance block list** — an activity whose actor is on a blocked
  domain gets a silent **202** accept-and-drop (no handler, no archive),
  so the blocked peer can't tell it's filtered
  (`inbox_controller.ex:54-58,124-131`).

## 4. Object Integrity Proofs (FEP-8b32, `eddsa-jcs-2022`)

Implemented **both directions** (`fedi/oip.ex`). Construction mirrors
fedify's `createProof` byte for byte: `proofConfig` is rebuilt from the
*document's* `@context` plus the proof's fields, `hashData =
sha256(jcs(config)) <> sha256(jcs(unsecured doc))`, signed with Ed25519,
`proofValue` is base58btc multibase (`oip.ex:9-26,204-205`,
`canon.ex:jcs_hash/1`).

- **Inbound gate** — `Oip.verify_inbound/1` runs after the HTTP
  signature passes. A present, *checkable* proof that fails ⇒ **401**;
  it must not silently fall through to HTTP-sig-only handling. Absence
  (`:no_proof`) or only-unsupported-cryptosuite proofs
  (`:no_checkable_proof`) fall back to the HTTP signature, which already
  authenticated the request (`inbox_controller.ex:60-65,100-121`,
  `oip.ex:95-113`).
- **Key binding** — the proof key's `controller` must equal the
  activity's `actor`; a valid proof by an unrelated key proves nothing
  (`oip.ex:191-196`). The key is resolved from the proof's
  `verificationMethod`, read as a Multikey from a standalone document or
  the actor's `assertionMethod` (`oip.ex:174-189`), with one stale-cache
  re-fetch retry (`oip.ex:151-172`).
- **Egress order** — for most builders the proof is attached *first* and
  the LD signature signs over it (`sign_and_prove/2`,
  `builders.ex:327-331`), so Mastodon-family receivers (which
  canonicalize everything but `signature`) still verify the LD-sig and
  fedify-family receivers (which strip both `signature` and `proof`)
  verify the proof. `note`/`dm` are the exception: they have post-sign
  compatibility injections, so there the proof is attached **last** to
  cover what is actually delivered (`builders.ex:18-24,92-98,149-154`).
- **Conditional** — a proof is attached only when the payload carries
  the actor's Ed25519 key (`ed25519PrivateKeyJwk`/`ed25519KeyId`);
  absent on rows the backfill hasn't reached, where the RSA LD signature
  still carries the activity (`builders.ex:311-322`).

## 5. Linked-Data signatures (RsaSignature2017) — emitted for reach, not trusted inbound

We **emit** RsaSignature2017 LD-signatures on outbound activities
(`fedi/ld_signature.ex:37-54`, via `builders.ex:303-307`) because that
is the legacy suite the Mastodon-family fediverse actually understands;
newer LD suites are not read there. Canonicalization is URDNA2015/
RDFC-1.0 over JSON-LD expanded against **vendored** contexts, then
sorted N-Quads + SHA-256 — byte-identical to fedify's `signJsonLd`
(`fedi/canon.ex:1-55`).

We do **not** trust LD-signatures on the way *in*. The inbound pipeline
authenticates on the HTTP signature (§3) and FEP-8b32 (§4); the
`LdSignature.verify/2` function exists only so tests can prove
canonicalization compatibility against fedify fixtures — "the inbound
pipeline relies on HTTP signatures, not on this"
(`ld_signature.ex:56-60`).

Known, pre-existing tradeoff: the post-signature compatibility
injections (§7) land *after* the LD signature for `note`/`dm`, so the
LD-sig does not cover them. Direct delivery is still authenticated by
the HTTP signature (`builders.ex:11-16`).

## 6. JSON-LD contexts: vendored, network refused

`Canon.ContextLoader` serves a fixed set of context documents from
memory and **refuses the network** for anything else — signing must
never depend on `w3id.org` being up (its redirect chain is half-dead),
and a runtime-fetched context would let a third party alter what our
signatures mean (`canon.ex:12-17,57-106`). A non-vendored URL returns
`{:error, "context … is not vendored"}`.

Vendored (`elixir/priv/fedify/contexts/`):

| URL | File |
| --- | --- |
| `https://www.w3.org/ns/activitystreams` | `activitystreams.json` |
| `https://w3id.org/security/v1` | `security-v1.json` |
| `https://w3id.org/identity/v1` | `identity-v1.json` |
| `https://w3id.org/security/data-integrity/v1` | `security-data-integrity-v1.json` |
| `https://w3id.org/security/multikey/v1` | `security-multikey-v1.json` |
| `https://www.w3.org/ns/did/v1` | `did-v1.json` |
| `https://gotosocial.org/ns` | `gotosocial-ns.json` |

Each is parsed once per node and memoised in `:persistent_term`
(`canon.ex:87-105`).

## 7. Quotes (FEP-e232, Misskey aliases)

On **egress** a quote is emitted three ways for maximum reach
(`builders.ex:347-364`): the Misskey-style `quoteUrl` and
`_misskey_quote` top-level properties, **and** a FEP-e232 `tag` entry of
`type: "Link"` whose `rel` is `_misskey_quote`. (The FEP-044f `quote`
property is *not* emitted — see §9.)

On **ingress** all of these are tolerated and read in one place
(`extract.ex:46-80`): `quoteUrl`, `quoteUri`, `_misskey_quote`, or a
FEP-e232 `tag` Link whose `rel` contains `_misskey_quote` or `e232`.

## 8. HTTP-signature double-knock (per host)

The fediverse is mid-migration from draft-cavage to RFC 9421, and we
can't know what a host speaks until we try. The delivery worker
"double-knocks" and learns per host (`delivery/.../sig_spec.ex`,
`delivery/.../worker.ex:84-131`):

- **First guess defaults to RFC 9421**, the direction the ecosystem is
  moving (`sig_spec.ex:36,44-53`).
- POST with the chosen spec; if the inbox answers a signature-rejection
  status (**400 or 401** only — `knock?/1`, `sig_spec.ex:69-77`),
  re-sign **once** with the other spec.
- Whichever spec the host accepts is remembered (ETS, **7-day** TTL), so
  steady state is one POST. If both are rejected we learn nothing — it's
  a key/clock/block problem, not a spec one — and keep probing later
  (`worker.ex:90-131`, `sig_spec.ex:40,55-67`).
- 403/404/410/429/5xx are **not** knock-worthy; knocking there would
  just double every POST (`sig_spec.ex:69-77`).

Cavage signs the Mastodon-compatible minimal set `(request-target) host
date digest content-type`; RFC 9421 signs fedify's component set
`@method @target-uri @authority host date content-digest`
(`http_signature.ex:111-123,250-275`). Authorized-fetch GETs are always
cavage — every current peer accepts it (`http_signature.ex:60-65`).

## 9. Follower-collection synchronization (FEP-8fcf)

Implemented **both directions** (`delivery/.../followers_sync.ex`):

- **Emit** — outbound shared-inbox deliveries by a local actor carry a
  `Collection-Synchronization` header: `collectionId`, `url`, and a
  SHA-256 digest of the sorted accepted-follower URIs
  (`followers_sync.ex:38-72`; attached in `worker.ex:66-68,266-279`).
- **Consume** — when a *remote* actor's delivery carries the header, the
  gateway enqueues a `FollowerSyncWorker` job (parsing is a pure regex
  on the gateway; reconciliation is deferred to the delivery node)
  (`inbox_controller.ex:13-16,81,207-232`).
- **Irreversible-loss guard** — `reconcile/2` refuses to prune on an
  empty or non-inline (paginated-only) collection. Local follow edges
  have no archive and no remote to refetch; a genuinely stale edge just
  lingers until an explicit `Undo(Follow)` — the cheap, recoverable side
  of the trade (`followers_sync.ex:17-32,79-119`). A delivery looped
  back to our own shared inbox (local actor URI) is skipped so it can't
  wipe local edges (`inbox_controller.ex:213-220`).

## 10. Interop tuning (per server, as named in the code)

These are the servers the live code names a specific accommodation for.
"Family-covered" servers (Firefish/Iceshrimp-as-Misskey-fork, Akkoma as
Pleroma-fork, Fedibird as Mastodon-fork) inherit the family's tuning;
they are not separately special-cased.

| Server | Accommodation | Where |
| --- | --- | --- |
| **Mastodon** | full-IRI `as:Public`; RsaSignature2017 LD-sig for reach; cavage minimal header set; Secure-Mode signed actor fetch; reads emoji-react as a plain `Like` | `audience.ex`, `ld_signature.ex:4-7`, `http_signature.ex:16-19`, `fetcher.ex:5`, `builders.ex:206-227` |
| **Misskey / Sharkey** | `_misskey_content` MFM side channel; `quoteUrl`/`_misskey_quote` aliases; emoji-react-as-`Like`-with-`content`+`Emoji` tag; auth-fetch signed GET | `builders.ex:206-227,335-364`, `extract.ex:46-95`, `fetcher.ex:5` |
| **hackers.pub / Hollo** (fedify-family) | RFC 9421 preferred (double-knock default); FEP-8b32 OIP verified preferentially; Multikey key resolution | `sig_spec.ex:6-23`, `oip.ex:5-8`, `verifier.ex:69-75` |
| **Pleroma** | note: its `EmojiReact` gets quarantined, so we emit emoji reactions as `Like`-with-`content` for broad acceptance | `builders.ex:206-210` |
| **iceshrimp** | full-IRI `as:Public` (it gates visibility on the exact string); reverse-webfinger from actor URL → acct supported; note-fetch route so single notes render on its timeline | `audience.ex:6-9`, `webfinger_controller.ex:62-65`, `note_controller.ex:8-12` |
| **GoToSocial** | its `https://gotosocial.org/ns` context vendored so its activities canonicalize without a network fetch | `canon.ex:73` |

## 11. What we do NOT do (yet)

Grounded in the code's own TODOs and tradeoffs — not aspirational.

- **FEP-044f `quote` property is not emitted.** We send the Misskey
  aliases and the FEP-e232 tag Link (§7) but not the FEP-044f `quote`
  property, so Mastodon renders our quotes as "legacy" (no inline
  preview) and Hollo's interaction-policy gate sees nothing to honour.
  Full support means adding `"quote"` + its `@context` term before
  signing (`TODO(FEP-044f)`, `builders.ex:338-346`).
- **QuoteRequest / QuoteAuthorization round trip is not handled.**
  hackers.pub/Hollo send `QuoteRequest` when quoting a gated post and
  expect a `QuoteAuthorization` (or `Reject`); we don't, so their quotes
  of our posts fall back to legacy handling. The work is shaped like the
  Follow → Accept flow and belongs next to it (`TODO(FEP-044f)`,
  `inbox.ex:26-30`).
- **No defensive force-array on egress.** `to`/`cc` and friends are
  emitted as the lists `Audience` builds; there is no guard that coerces
  single-string properties into one-element arrays before sending. We
  rely on receivers accepting the shapes we actually produce
  (`audience.ex`, `builders.ex`).
- **`manuallyApprovesFollowers` is not gated.** The inbound Follow
  handler builds an `Accept` unconditionally on any resolvable Follow —
  there is no lockable-account / pending-approval state. Adding lockable
  accounts means setting the actor flag *and* gating the Accept enqueue
  on a `pending_approval` state (`inbox.ex:56-88`; cf. retired-worker
  note in `FEDIFY.md` §3.5).
- **Inbound RsaSignature2017 LD-signatures are not verified for trust.**
  Inbound authentication is HTTP-signature + FEP-8b32 only;
  `LdSignature.verify/2` is test-only (`ld_signature.ex:56-60`, §5).
- **HTTP-signature verification reads only the legacy `publicKey` PEM.**
  fedify-family actors also publish `assertionMethod` Multikey entries
  (FEP-521a); we read those for OIP keys but not yet for HTTP-signature
  keys. Every current HTTP-sig peer still ships the legacy PEM
  (`TODO(FEP-521a)`, `verifier.ex:69-75`).

## About this doc

Drafted by Shiro (Claude Opus 4.8), an AI assistant working with
@nyanrus, from the live `SukhiFedi.Fedi.*` code at v0.4.x. If any pin
has drifted or a claim reads as more than the code does, that's a
misreading on my part — tell me and I'll re-check the function.

## Misskey avatar decorations

ActivityPub actors carry no decoration. For actors whose `@context` declares
the `misskey` namespace (Misskey and forks), a background job
(`Federation.MisskeyDecorationsWorker`) reads `POST https://<host>/api/users/show` with `{"username": …}`
and stores `avatarDecorations` on the shadow row. It is best effort and silent:
an origin that is down or closes the endpoint just leaves the icon undecorated.
Images are served through `/proxy/deco/:id/:n` (no viewer IP to the origin) and
drawn over the icon by `web/src/lib/components/Avatar.svelte`.
