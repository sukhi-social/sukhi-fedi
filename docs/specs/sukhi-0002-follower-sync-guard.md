<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-0002: Safe reconciliation of followers collections

- Status: Draft. Implemented in `delivery/lib/sukhi_delivery/delivery/followers_sync.ex`.
- Identifier: `https://sukhi.social/spec/sukhi-0002/1` (domain and `/spec/` path fixed, see [README](README.md)).
- Builds on: FEP-8fcf (followers collection synchronization).

## 1. Problem

FEP-8fcf lets a receiver compare a digest and fix its follower list for a remote actor. It does not say what to do when the collection is empty, paged, or looped back. A receiver that prunes on those inputs deletes follow edges that cannot be recovered.

## 2. Terms

A **local edge** is a follow relation whose follower is on this server and which has no archive and no remote copy to fetch again.

## 3. Rules

1. The receiver MUST NOT remove any edge when the fetched collection is empty.
2. The receiver MUST NOT remove any edge when the collection is only reachable by pages and no page was read in full (non-inline collection).
3. The receiver MUST skip a delivery whose actor is on its own server. A delivery that came back to the own shared inbox MUST NOT change local edges.
4. When the digest differs and the collection is complete, the receiver MAY remove edges that are absent from it, and MAY queue the work apart from the request that carried the header, so the inbox answers first.
5. A stale edge that stays is accepted. It goes away at an explicit `Undo(Follow)`.

## 4. Reason

Wrongly keeping an edge costs one extra delivery. Wrongly removing it silently ends a person's timeline. The rules choose the first cost.

## 5. Sender side

The sender follows FEP-8fcf: outbound shared-inbox deliveries by a local actor carry `Collection-Synchronization` with `collectionId`, `url`, and the SHA-256 digest of the sorted accepted-follower URIs.
