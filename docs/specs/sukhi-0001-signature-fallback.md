<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-0001: Signature scheme fallback

- Status: Draft. Implemented in `delivery/lib/sukhi_delivery/delivery/sig_spec.ex` and `worker.ex`.
- Identifier: `https://sukhi.social/spec/sukhi-0001/1`
- Builds on: RFC 9421 (HTTP Message Signatures), draft-cavage-http-signatures-12.
- Terms, and what MUST / SHOULD / MAY mean: [README](README.md#how-to-read-the-specifications). Japanese: [README.ja.md](README.ja.md).

## In one paragraph

When a server sends an activity to another server, it signs the HTTP request. There are two ways to write that signature, and the sender cannot know which one the receiver accepts until it tries. So the sender tries one, and **only if the receiver answers 400 or 401** it tries the other, once. It then remembers which one worked for that receiver.

## The problem

Call the two schemes A (RFC 9421) and B (cavage, the older one). A receiver accepts only A, only B, or both.

- Always sending A fails for B-only receivers.
- Always sending both doubles the traffic to every receiver.
- Neither specification tells a sender how to find out which one a receiver accepts.

So a "try, and change if refused" procedure has to be written down.

## Sender rules

1. For a receiver the sender knows nothing about, the sender SHOULD sign with A first. Starting with B is also fine, because rule 2 makes delivery work either way.
2. If the receiver's inbox answers **400 or 401**, the sender MUST send the same activity once more, signed with the other scheme.
   - Reason: without this rule, a sender and a receiver with no scheme in common can never talk.
3. For any other status (403, 404, 410, 429, 5xx, and so on) the sender SHOULD NOT resend.
   - Reason: these statuses do not mean "wrong scheme". A resend would not fix the problem and would only add traffic.
4. When the second request is accepted, the sender SHOULD remember the accepted scheme for that receiver. The memory MAY expire after 7 days. When it expires, start again at rule 1.
5. When both requests are refused, the sender SHOULD NOT remember anything.
   - Reason: if the cause were the scheme, one of the two would have passed. Both failing points to a key, a clock difference, or a block.
6. While a memory exists, the sender SHOULD send one request per delivery.

### What this guarantees

Let S be the set of schemes the receiver accepts. If S contains A or B, delivery succeeds within 2 requests. After the sender has remembered, it succeeds in 1 request every time. If S is empty, both requests are refused, and by rule 5 nothing is remembered.

## What the signature covers

- A (RFC 9421): `@method @target-uri @authority host date content-digest`
- B (cavage): `(request-target) host date digest content-type`
- For a request with a body, the digest of that scheme MUST be inside the signed set. Being present in the request is not enough.
  - Reason: if the digest is not signed, someone can replace the body and the signature stays valid.

## Receiver rules

1. A request with a `Signature-Input` header MUST be checked as A. Any other signed request MUST be checked as B.
2. A request with a body MUST be refused when its digest is not in the signed set.
3. The accepted clock difference SHOULD be at least 300 seconds. sukhi uses 3600.
4. A refused signature MUST be answered with 400 or 401.
   - Reason: the sender decides whether to retry (sender rule 2) from this status. Any other status stops the fallback.

## When fetching an actor

A signed GET that fetches an actor (authorized fetch) MAY always use B. sukhi does. Every receiver seen so far accepts it. Revisit this when that stops being true.

## Open points

- RFC 9421 has `Accept-Signature`, a way for a receiver to announce what it accepts. No ActivityPub server is known to send it, so this specification does not depend on it.
- The 7-day figure comes from sukhi's settings. It has not been tuned against measurements.
