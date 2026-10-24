<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Signatures in Pull Federation

Question: is every activity signed, and how do draft-cavage and RFC 9421
compare for this design?

## What the prototype does

Until this change: **nothing was signed.** Activities were plain maps and
`Puller` had one hook, `verify`, defaulting to "accept". The hook is the
right shape (one place, used by pull *and* push, `Puller.apply_activity/3`),
but the sender never produced a signature.

Now (`PullFederation.Proof`, `test/proof_test.exs`, 7 tests):

- `Origin` signs each activity **once, at publish**, with the actor's key
  (`signers: %{actor => {key_id, private}}`), whatever the number of
  followers and whatever the route (pull, push, hybrid). Ed25519, the
  shape of FEP-8b32 `eddsa-jcs-2022` that `docs/FEDERATION.md` section 4
  already implements. The prototype canonicalises with Erlang's
  deterministic term encoding; the real thing uses JCS (RFC 8785).
- The signed bytes include `actor`, so an activity cannot be relabelled.
- `Proof.verifier(keys)` is plugged into `Puller` as `verify`. The key is
  found by **actor**, not by the server that delivered it, so a
  stream's origin cannot forge activities (or Deletes) of an actor whose
  key it does not hold, and an unsigned activity is rejected.
- Not modelled: fetching and caching the actor's key document (once per
  actor, not per activity), key rotation, and the policy "the actor must
  live on the host that served the stream" (`docs/FEDERATION.md` 3.2 has
  the push equivalent: signer host bound to claimed actor host).

## Why pull needs per-activity proofs more than push does

| | push | pull |
|---|---|---|
| Transport | `POST /inbox`, a request with a body | `GET` stream, a response with a body |
| What the HTTP signature covers | the whole activity (body digest is signed) | the **request** only (who is asking, which cursor) |
| What authenticates the activity | the request signature | nothing, unless the activity carries its own proof |
| Signed by | the origin, **once per target** per try | the origin, **once per activity** (proof) + the receiver, once per pull (request) |

An HTTP signature authenticates one message. In push, the message is the
activity. In pull the message that carries activities is a response, and
the draft-cavage scheme cannot sign responses at all. RFC 9421 can, but a
response signature needs the digest of the whole body (`Content-Digest`),
which a stream does not have until it ends. So the natural unit is the
activity itself: a proof inside it, checked by the receiver, valid wherever
the bytes came from (also from a cache, a snapshot, a relay, a retry).

## draft-cavage-http-signatures-12 vs RFC 9421

| | draft-cavage-12 (Mastodon, de facto) | RFC 9421 (HTTP Message Signatures, Feb 2024) |
|---|---|---|
| Status | expired Internet-Draft, never an RFC | Proposed Standard |
| Headers | one `Signature: keyId="..",algorithm="..",headers="..",signature=".."` | `Signature-Input` (what was signed, with params) + `Signature` (value), RFC 8941 structured fields |
| What is signed | a list of header names plus the pseudo-header `(request-target)` | "components": `@method`, `@target-uri`, `@authority`, `@path`, `@query`, header fields, and more, serialised unambiguously |
| Body | `Digest: SHA-256=..` (RFC 3230, obsolete) must be in the list | `Content-Digest` (RFC 9530) must be in the covered components |
| Time | `Date` header / `created`, `expires` params, no required semantics | `created`, `expires`, `nonce`, `tag` as signature parameters |
| Algorithms | `rsa-sha256`, `hs2019` (algorithm hidden in the key) | registry: `ed25519`, `rsa-pss-sha512`, `ecdsa-p256-sha256`, `hmac-sha256`, ... named in `alg` |
| Several signatures | no | yes (`sig1`, `sig2`, e.g. an origin and a relay) |
| Responses | no | yes, with `;req` to bind a response to its request |
| Negotiation | no | `Accept-Signature` |
| Known weakness | `(request-target)` and header-list ambiguity; nothing forces the digest to be covered | covered components are explicit; still allows a sender to leave the digest out unless the verifier insists |

This repo's verifier (`docs/FEDERATION.md` section 3) already accepts
both, tells them apart by the presence of `Signature-Input`, insists that
the digest is in the signed set (not merely present), and uses a 3600 s
clock window.

## What this means for the pull endpoints

- **Pull request** (`GET`, no body, so no digest): sign with RFC 9421,
  covering `@method`, `@target-uri`, `@authority` and the cursor if it is
  in a header, with a **short** `created`/`expires` (60 s rather than
  3600 s) and a `tag` naming the endpoint. A GET is replayable by design,
  so what bounds the damage is the short window plus the fact that a
  replay yields only what that domain could already read. Fall back to
  draft-cavage only for peers that cannot do 9421; the receiver still
  needs the origin to answer.
- **Stream**: newline-delimited activities, **each with its own proof**
  (FEP-8b32). No response signature, so streaming stays possible.
- **No RsaSignature2017 on pull.** That legacy suite exists so that
  Mastodon-family servers can verify forwarded activities (`FEDERATION.md`
  section 5). Pull is a new endpoint nobody legacy reads, so it needs only
  the proof the receivers actually check. Push keeps emitting what it
  emits today.
- **Notifications and ETags stay unsigned** on purpose. They are hints:
  a forged one costs the receiver one pull, which is rate-limited and
  verified (part 5 of the README).
- **Snapshot buckets** are public data and also only hints; the activity
  that results arrives through the stream.
- Checks that must stay at the boundary: proof valid, key bound to the
  actor, actor's host equals the host that served the stream (not
  implemented in the prototype), and then nothing downstream re-verifies.

## Cost (measured: `mix run bench/sign.exs`, one core, OTP crypto)

| operation | microseconds |
|---|---|
| Ed25519 sign | 114 |
| Ed25519 verify | 147 |
| RSA-2048 sign | 1205 |
| RSA-2048 verify | 46 |

Signature size: Ed25519 64 bytes (88 in base64), RSA-2048 256 (344).

CPU spent by the whole federation on *one post*, D follower domains, when
push signs one RSA request per domain and pull signs one Ed25519 proof
plus one RSA request per pull (P posts per pull):

| D | P | push total (origin part) | pull total (origin part) |
|---|---|---|---|
| 1 000 | 1 | 1251 ms (1205) | 1398 ms (46) |
| 1 000 | 10 | 1251 ms (1205) | 272 ms (5) |
| 100 000 | 1 | 125 s (120.5 s) | 140 s (4.6 s) |
| 100 000 | 10 | 125 s (120.5 s) | 27 s (0.5 s) |

Reading: for a single post pull is not cheaper overall, but it moves the
cost from the origin (26x less) to the receivers, who pay for their own
requests. When a pull carries several posts, the total drops too. RSA
signing dominates both; a receiver using an Ed25519 key for its pull
requests (`alg="ed25519"` in 9421) would cut the receiver side from 1.3
to 0.3 ms per pull, which cavage cannot express.
These are single-machine timings of one library, not a production figure.
