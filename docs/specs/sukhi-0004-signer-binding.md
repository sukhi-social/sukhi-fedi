<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-0004: Binding the signer to the claimed actor

- Status: Draft. Implemented in `web/inbox_controller.ex:51-97` and `ap/instructions` (`trusted_inline_origin?/2`).
- Identifier: `https://sukhi.social/spec/sukhi-0004/1`
- Builds on: ActivityPub inbox delivery, RFC 9421, draft-cavage-12.
- Terms, and what MUST / SHOULD / MAY mean: [README](README.md#how-to-read-the-specifications). Japanese: [README.ja.md](README.ja.md).

## In one paragraph

A correct signature does **not** prove that the activity was sent by someone allowed to send it. Besides checking the signature, a receiver must check that **the signer is tied to the actor named inside the activity**.

## The problem

In logic terms:

- P: "this signature is valid for some key."
- Q: "this activity was sent by the actor written inside it."

Checking a signature establishes P. P does not imply Q. A malicious server X can sign an activity correctly with its own key and write `actor: <a user on another server Y>` inside it. The signature stays valid. X now speaks as Y's user.

The same holds for data embedded in the activity (an inline object). X can embed content that pretends to come from Y.

So the receiver adds a third condition, R: "the signer and the named actor have the same owner." From P and R together, Q may be trusted.

## Rules

1. The receiver MUST verify the signature **before** it parses the body.
2. A signature that is wrong or missing MUST be answered with 401, and the activity MUST NOT run.
3. After verification the receiver MUST know who signed: the `keyId` and the owner of that key.
4. When the host of the claimed `actor` differs from the host of the signer, the receiver MUST NOT trust data embedded in the activity. It MUST fetch that data from its owner's server, or ignore it.
5. The URL used to check the signature SHOULD be built from the configured public domain. It SHOULD NOT come from the request's `Host` header, because proxies rewrite that header.
6. An activity from a blocked domain MAY be answered with 202 and dropped without work, so the sender cannot tell it is being filtered.
7. When a FEP-8b32 proof is present and can be checked, a failed check MUST be answered with 401. The receiver MUST NOT fall back to the HTTP signature. When the proof is absent, or uses only a cryptosuite the receiver does not support, it falls back to the HTTP signature that already passed. The `controller` of the proof's key MUST equal the activity's `actor`.

## Reason

- Rules 3 and 4 establish R. A June 2026 audit found that only P was being checked, and the gap was closed (`FEDERATION.md` §3).
- Rule 7 removes the route by which a proof that can be checked and fails is quietly ignored.
