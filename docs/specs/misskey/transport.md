<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Transport

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

1. Misskey accepts `POST /inbox` and `POST /users/:user/inbox`. Both have a 64 KB body limit. **[src]** `server/ActivityPubServerService.ts`
2. Accepted request content types are `application/activity+json` and `application/ld+json`. Anything else gets 415. A body that is not JSON gets 400. **[src]** same file
3. Responses carry `application/activity+json; charset=utf-8`, or the `ld+json` profile type when the client asks for it. **[src]** same file
4. When federation is set to `none`, both inbox routes answer 403. **[src]** same file
5. A good delivery is answered with 202 and queued. The activity is checked again in the queue. **[src]** same file; **[study]**
6. GET endpoints do not check HTTP signatures in the file read. They are gated by the federation setting and by visibility rules. **[src]** same file. Whether a newer authorized-fetch option exists was **[not seen]**.
