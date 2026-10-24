<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-0002: Safe reconciliation of followers collections

- Status: Draft. Implemented in `delivery/lib/sukhi_delivery/delivery/followers_sync.ex`.
- Identifier: `https://sukhi.social/spec/sukhi-0002/1`
- Builds on: FEP-8fcf (followers collection synchronization).
- Terms, and what MUST / SHOULD / MAY mean: [README](README.md#how-to-read-the-specifications). Japanese: [README.ja.md](README.ja.md).

## In one paragraph

Servers keep records of who follows whom, and FEP-8fcf lets them compare records and repair differences. This specification adds one rule to the repair: **when the list you fetched is empty, or only partly visible, delete nothing.**

## The problem

Under FEP-8fcf the sender attaches a digest (a short value) computed from its list of followers. The receiver computes the same value from its own records and compares. If the values differ, one of the two records is out of date.

That much is specified. What is not specified is **how to repair the difference**.

- The receiver fetches the list and gets an empty one. Is the list really empty, or did the fetch fail? It cannot tell.
- The list is split into pages and only the first page was read. For a follow relation not on that page, is it "absent" or "not read yet"?

If the receiver then deletes "whatever is not in the list", it deletes relations it should have kept.

## Terms

**Local relation**: a follow relation whose follower is on this server. It has no archive, and the other server cannot be asked for it again. Once deleted, it is gone.

## Rules

1. When the fetched collection is **empty**, the receiver MUST NOT remove any relation.
2. When the collection is split into pages and was not read in full (it is **not inline**), the receiver MUST NOT remove any relation.
3. A delivery whose actor is on the receiver's own server MUST be skipped. A delivery that came back to the server's own shared inbox must not change local relations.
4. Only when the digest differs and the collection was read **completely**, the receiver MAY remove relations that are absent from it. It MAY run this work apart from the request that carried the header, so the inbox can answer first.
5. A stale relation that stays is accepted. It disappears when the other side sends `Undo(Follow)`.

## Reason

There are two ways to be wrong.

| Mistake | Result | Can it be undone? |
| --- | --- | --- |
| Remove a relation that should stay | A person's posts silently stop appearing | No |
| Keep a relation that should go | One extra delivery is sent | Yes (a later Undo removes it) |

The rules accept the second mistake to avoid the first.

## Sender side

As in FEP-8fcf: a delivery to a shared inbox by a local actor carries a `Collection-Synchronization` header with `collectionId`, `url`, and the SHA-256 digest of the sorted URIs of the accepted followers.
