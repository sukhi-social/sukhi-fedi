<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Collections

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

Misskey serves four collections for a user, each with its own page size and paging parameter. Followers and following can be refused, and the featured path is not the usual one.

Source of this page: **[src]** `ActivityPubServerService.ts`

| Endpoint | Page size | Paging | Limits |
| --- | --- | --- | --- |
| outbox `/users/:user/outbox` | 20 | `since_id`, `until_id` | public and home notes that are not local-only |
| followers, following | 10 | `cursor` | 403 when the user's visibility is `followers` or `private` |
| featured `/users/:user/collections/featured` | all | none | public and home notes that are not local-only |

Note: the featured path is `/users/:user/collections/featured`, not `/users/:user/featured`. A reader that follows the `featured` property of the actor is not affected; one that guesses the path is.
