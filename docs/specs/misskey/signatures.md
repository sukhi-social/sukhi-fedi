<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: HTTP signatures

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

Misskey verifies only the older draft-cavage signature. It does not read RFC 9421. After the signature, it checks that the key's owner is the actor named in the activity, and that the activity's `id` is on the signer's host. A failure in the queue is permanent and silent: the sender already got 202.

## What Misskey does

### At the route **[src]** `server/ActivityPubServerService.ts`

The `Signature` header is parsed with `@peertube/http-signature`. The signed headers must include `(request-target)`, `host`, and `date`. These answer **401**: a header that cannot be parsed; `host` not signed; a `Host` header different from the configured host; `digest` not signed; a malformed `Digest`; an algorithm other than SHA-256; a body hash that does not match. A missing raw body, or a body without `actor`, answers 400.

Misskey signs its own deliveries with cavage only, over `(request-target) date host digest`. **[study]** `ApRequestService.ts`

Neither this file nor the queue processor mentions RFC 9421 or `Signature-Input`. **[src]** A clock or `Date` window is not checked in either file. Whether the signature library checks it was **[not seen]**.

### In the queue **[src]** `queue/processors/InboxProcessorService.ts`

The steps run in this order.

1. The host of the `keyId` must be allowed to federate. Otherwise: `Blocked request`.
2. A `keyId` that starts with `acct:` ends with `Old keyId is no longer supported.`
3. The key is found by `keyId`. If that fails, it is found by the activity's `actor`. A missing user, or a user without a public key, is a permanent failure.
4. The signature is verified against that key. There is no refetch of the key after a failed check in this file.
5. The key's owner must equal the activity's `actor`. A mismatch counts as a failed signature.
6. Only if step 4 or 5 fails, an `RsaSignature2017` Linked-Data signature on the activity is tried. Its `creator` must resolve to a user and key and match the `actor`. Any other signature type is a permanent failure. If it passes, the HTTP signature is not looked at again.
7. After either path, `activity.id` must be a string whose host equals the signer's host. Otherwise: permanent failure.
8. A `Delete` of an actor that Misskey does not know is skipped.

A permanent failure is not retried. FEP-8b32 proofs are not read at all. **[src]**

## Things to watch

- A sender that signs only with RFC 9421 is refused.
- The key's owner must equal `actor`, and `activity.id` must be on the signer's host.
- A FEP-8b32 proof adds nothing; the HTTP signature carries the trust.
- `RsaSignature2017` is used only when the HTTP signature fails.
- Permanent failures are silent: the route has answered 202 already, so the sender never learns of the failure.

## Not researched

The size of the allowed clock difference; whether the signature library checks `Date`; whether a key is fetched again after a failed check.
