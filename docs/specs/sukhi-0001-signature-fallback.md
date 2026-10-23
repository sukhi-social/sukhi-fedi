<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-0001: Signature scheme fallback and per-host memory

- Status: Draft. Implemented in `delivery/lib/sukhi_delivery/delivery/sig_spec.ex` and `worker.ex`.
- Identifier: `https://sukhi.social/spec/sukhi-0001/1` (provisional).
- Builds on: RFC 9421 (HTTP Message Signatures), draft-cavage-http-signatures-12.

## 1. Problem

Servers in the fediverse accept either draft-cavage or RFC 9421, or both. Neither document says how a sender finds out which one a receiver accepts. Without a rule, a sender either doubles every request or breaks delivery to half the network.

## 2. Sender behaviour

1. For a host with no memory, the sender SHOULD sign with RFC 9421 first. Either scheme may go first; the fallback below is what lets two servers talk.
2. If the inbox answers **400 or 401**, the sender MUST send the same activity once more, signed with the other scheme. Without this step a sender and a receiver with no scheme in common cannot talk.
3. The sender SHOULD NOT resend for any other status. In particular 403, 404, 410, 429, and 5xx do not mean a scheme problem, and a resend would double the load.
4. When the second request is accepted, the sender SHOULD remember the accepted scheme for that host. The memory MAY expire after 7 days. When it expires, the sender goes back to step 1.
5. When both requests are rejected, the sender SHOULD NOT remember anything. The cause is a key, a clock, or a block, not a scheme.
6. While memory exists, the sender SHOULD send one request per delivery.

## 3. Signed components

- RFC 9421: `@method @target-uri @authority host date content-digest`.
- cavage: `(request-target) host date digest content-type`.
- A request with a body MUST sign the digest header of its scheme. Present but unsigned does not count.

## 4. Receiver behaviour

1. A request with a `Signature-Input` header MUST be checked as RFC 9421. Any other signed request MUST be checked as cavage.
2. A receiver MUST reject a request with a body when the digest is not in the signed set.
3. The accepted clock difference SHOULD be at least 300 seconds. sukhi uses 3600.
4. A receiver that rejects a signature MUST answer 400 or 401, so a sender following section 2 can fall back.

## 5. Fetches

A signed GET for an actor (authorized fetch) MAY always use cavage. sukhi does: every peer seen so far accepts it. Revisit this when that stops being true.

## 6. Open points

- RFC 9421 has `Accept-Signature` for announcing accepted parameters. No fediverse server is known to send it, so this specification does not depend on it.
- The 7-day figure comes from the code. It is not tuned against measurements.
