<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-0004: Binding the signer to the claimed actor

- Status: Draft. Implemented in `web/inbox_controller.ex:51-97` and `ap/instructions` (`trusted_inline_origin?/2`).
- Identifier: `https://sukhi.social/spec/sukhi-0004/1` (domain fixed; the `/spec/` path is proposed, see [README](README.md)).
- Builds on: ActivityPub inbox delivery, RFC 9421, draft-cavage-12.

## 1. Problem

A valid signature proves that someone holds a key. It does not prove that the key owner may speak for the `actor` in the activity, or for the objects inside it. A receiver that checks the bytes only can be made to accept an activity and its embedded data from a different host.

## 2. Rules

1. The receiver MUST verify the signature before it parses the body.
2. A failed or missing signature MUST end in 401 and the activity MUST NOT run.
3. After verification the receiver MUST know the signer: the `keyId` and the owner of that key.
4. The receiver MUST NOT trust data embedded in the activity (an inline object) when the host of the claimed `actor` differs from the host of the signer. It MUST fetch such data from its origin or ignore it.
5. The URL the signature is checked against SHOULD be built from the configured public domain, not from the `Host` header, because proxies rewrite that header.
6. An activity from a blocked domain MAY be accepted with 202 and dropped without work, so the sender cannot tell that it is filtered.
7. When a FEP-8b32 proof is present and can be checked, a failure MUST end in 401. It MUST NOT fall back to the HTTP signature. A proof that is absent, or uses only an unsupported cryptosuite, falls back to the HTTP signature that already passed. The proof key's `controller` MUST equal the activity's `actor`.

## 3. Reason

Rules 3 and 4 close the gap found in the 2026-06 audit recorded in `FEDERATION.md` §3. Rule 7 stops a bad proof from being ignored.
