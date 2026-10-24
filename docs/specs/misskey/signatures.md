<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: HTTP signatures

- Part of [the Misskey specification](README.md); source tags and terms are explained there.

## In one paragraph

Misskey verifies only the older draft-cavage signature. It does not read RFC 9421. After the signature, it checks that the key's owner is the actor named in the activity, and that the activity's `id` is on the signer's host. A failure in the queue is permanent and silent: the sender already got 202.

## What Misskey does

### Checking an incoming delivery

At the route (the 401 list is in [transport](transport.md)), the `Signature` header is parsed with `@peertube/http-signature`: the signed headers must include `(request-target)`, `host`, and `date`, plus `digest`. Neither the route nor the queue mentions RFC 9421 or `Signature-Input`. A clock or `Date` window is not checked in either file; whether the library checks it was **[not seen]**.

In the queue (**[src]** `queue/processors/InboxProcessorService.ts`) the steps run in this order (step 0 is a shortcut that comes first):

0. A `Delete` of an actor that Misskey does not know is skipped before anything else.
1. The host of the `keyId` must be allowed to federate, else `Blocked request`.
2. A `keyId` that starts with `acct:` ends with `Old keyId is no longer supported.`
3. The key is looked up by `keyId` in Misskey's database. If it is not there, Misskey looks the signer up by the activity's `actor`, and **fetches the actor from its server if it is unknown**. So the first delivery from a stranger can succeed. A 4xx while fetching ends the job for good; a 5xx makes it retry. If no user or no public key results, the job ends for good.
4. The signature is verified with that key. The key is not fetched again after a failed check in this file.
5. The key's owner (`user.uri`) must equal the activity's `actor`. A mismatch counts as a failed signature.
6. Only if step 4 or 5 fails, and the activity has a `signature` of type `RsaSignature2017`, a Linked-Data signature is tried. Misskey fetches the actor named by `creator`, compacts the activity as JSON-LD (rejecting forbidden directives such as remote contexts), and verifies the signature over it. Any other signature type ends the job. If it passes, the HTTP signature is not looked at again.
7. After either path, `activity.id` must be a string whose host equals the signer's host, else the job ends.

A job that ends "for good" is not retried. FEP-8b32 proofs are not read at all.

### Signing what Misskey sends

**[src]** `core/activitypub/ApRequestService.ts`

- A `POST` has the headers `Date` (HTTP date, UTC), `Host`, `Content-Type: application/activity+json`, `Digest: SHA-256=<base64 of the SHA-256 of the body>`, and `Signature`.
- `Signature` is `keyId="<origin>/users/<id>#main-key",algorithm="rsa-sha256",headers="(request-target) date host digest",signature="<base64>"`. The signing string is the four lines `(request-target): post /path`, `date: ...`, `host: ...`, `digest: ...`, joined by newlines.
- Keys are RSA; Misskey generates RSA pairs. Whether it accepts other key types on receipt was **[not seen]**.
- Misskey also signs its `GET` requests when it fetches an object (headers `(request-target) date host`, with `Accept: application/activity+json, application/ld+json; profile="https://www.w3.org/ns/activitystreams"`), under the key of a local user.
- Misskey adds the `RsaSignature2017` Linked-Data signature to some activities (`attachLdSignature`: `creator` is the same `#main-key`, plus a random `nonce`); [activities](activities.md) shows its shape.

## Things to watch

- A sender that signs only with RFC 9421 is refused.
- The `Digest` must be `SHA-256=...` and `host` must be signed; a signature without them is refused at the route, before the signature is looked at.
- The key's owner must equal `actor`, and `activity.id` must be on the signer's host.
- A FEP-8b32 proof adds nothing; the HTTP signature carries the trust.
- `RsaSignature2017` is used only when the HTTP signature fails.
- Permanent failures are silent: the route has answered 202 already, so the sender never learns of the failure.

## Not researched

The size of the allowed clock difference; whether the signature library checks `Date`; whether a key is fetched again after a failed check (the lookup by `actor` in step 3 may refresh it; that code was not read).
