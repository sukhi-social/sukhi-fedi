<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Transport

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

Misskey takes activities by `POST` to an inbox, answers quickly with 202, and checks the signature later in a queue. The route only checks the form of the request, so a 202 does not mean the activity was accepted.

## What Misskey does

1. It accepts `POST /inbox` and `POST /users/:user/inbox`. Both have a 64 KB body limit. **[src]** `server/ActivityPubServerService.ts`
2. It accepts only the content types `application/activity+json` and `application/ld+json`. Any other type gets 415. A body that is not JSON gets 400. **[src]** same file
3. It answers with `application/activity+json; charset=utf-8`, or with the `ld+json` profile type when the client asks for it. **[src]** same file
4. When federation is set to `none`, both inbox routes answer 403. **[src]** same file
5. A delivery that passes the form checks is answered with 202 and queued. The activity is checked again in the queue (see [signatures](signatures.md)). **[src]** same file; **[study]**
6. `GET` endpoints do not check HTTP signatures in the file that was read. They are limited by the federation setting and by visibility rules. A newer authorized-fetch option was **[not seen]**.

## Things to watch

- A body larger than 64 KB is refused. The status code it answers with was not read. A resend of the same body is refused again.
