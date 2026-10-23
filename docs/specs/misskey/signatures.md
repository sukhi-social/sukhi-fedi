<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: HTTP signatures

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

1. Misskey signs outbound deliveries with draft-cavage only. Signed headers: `(request-target) date host digest`. There is no RFC 9421 signing. **[study]** `ApRequestService.ts`
2. Inbound, the `Signature` header is parsed with `@peertube/http-signature`. The signed headers must include `(request-target)`, `host`, and `date`. **[src]** `ActivityPubServerService.ts`
3. These cases answer 401: parse failure, `host` not signed, `Host` header different from the configured host, `digest` not signed, malformed `Digest`, an algorithm other than SHA-256, a body hash that does not match. **[src]** same file
4. A missing raw body gives 400. A body with no `actor` gives 400. **[src]** same file
5. Misskey does not read an RFC 9421 `Signature-Input` header on the inbox. Neither the route file nor the queue processor mentions it. **[src]** `ActivityPubServerService.ts`, `queue/processors/InboxProcessorService.ts`. A sender that signs only with RFC 9421 is rejected. sukhi handles this with the fallback in [sukhi-0001](../sukhi-0001-signature-fallback.md). **[sukhi]**
6. A clock or `Date` window is not checked in either file. Whether `@peertube/http-signature` checks it was **[not seen]**. The size of the allowed difference is therefore unknown.

### Checks in the queue **[src]** `queue/processors/InboxProcessorService.ts`

The route (above) only checks the form. The signature is verified later, in this order.

1. The host of `keyId` must be allowed to federate. Otherwise the job ends with `Blocked request`.
2. A `keyId` that starts with `acct:` ends with `Old keyId is no longer supported.`
3. The key is found by `keyId`. If that fails, it is found by the `actor` of the activity (the code comment says this can fetch remotely). A missing user or a user without a public key is a permanent failure (no retry).
4. The signature is verified against that key. There is no refetch of the key after a failed check in this file.
5. The owner of the key must equal the `actor` of the activity. A mismatch counts as a failed signature.
6. Only when step 4 or 5 fails, an `RsaSignature2017` Linked-Data signature on the activity is tried. Its `creator` must resolve to a user and key, and it must match the `actor`. A type other than `RsaSignature2017` is a permanent failure. Once it passes, the HTTP signature is not checked again.
7. After either path, `activity.id` must be a string whose host equals the host of the signer. Otherwise the job fails permanently.
8. A `Delete` of an actor that Misskey does not know is skipped.

Consequences:
- Every `id` that sukhi puts on an activity must be on the same host as the key that signs it. sukhi's ids are on its own domain. **[sukhi]** `fedi/builders.ex`
- FEP-8b32 proofs are not read. **[src]** The only Linked-Data proof handled is `RsaSignature2017`. A sukhi proof is ignored, and the HTTP signature carries the trust.
- sukhi's `RsaSignature2017` is only a fallback for Misskey, and is used when the HTTP signature check fails.
- A permanent failure is not retried. The sender gets 202 earlier at the route, so it never learns of the failure.
