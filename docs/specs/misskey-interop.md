<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey interoperability: a descriptive specification

- Kind: **descriptive**. It states what Misskey does, as read from its source. It does not say what anyone must do. Prescriptive rules for sukhi live in the numbered specifications ([README](README.md)).
- Subject: Misskey, `packages/backend/src` on the `develop` branch, read on 2026-10-23. No release tag was pinned, so the version is unknown. Forks (Sharkey, Firefish, Iceshrimp) are not covered.
- Status: Draft.

## 0. How to read this

Every statement is tagged with where it comes from.

| Tag | Meaning |
| --- | --- |
| **[src]** | Read in a Misskey source file on 2026-10-23. The file is named. |
| **[study]** | Taken from the delivery study in the project files (`federation/push-federation-ste.md`, source read 2026-10-22). |
| **[sukhi]** | Read in the sukhi code, with the file. |
| **[not seen]** | Looked for and not found in the files read. This is not proof of absence. |

The Misskey files were read through a summarising tool, not line by line by a person. A statement marked **[src]** should be checked against the file before it is relied on. Nothing here was tested against a live Misskey server.

## 1. Transport

1. Misskey accepts `POST /inbox` and `POST /users/:user/inbox`. Both have a 64 KB body limit. **[src]** `server/ActivityPubServerService.ts`
2. Accepted request content types are `application/activity+json` and `application/ld+json`. Anything else gets 415. A body that is not JSON gets 400. **[src]** same file
3. Responses carry `application/activity+json; charset=utf-8`, or the `ld+json` profile type when the client asks for it. **[src]** same file
4. When federation is set to `none`, both inbox routes answer 403. **[src]** same file
5. A good delivery is answered with 202 and queued. The activity is checked again in the queue. **[src]** same file; **[study]**
6. GET endpoints do not check HTTP signatures in the file read. They are gated by the federation setting and by visibility rules. **[src]** same file. Whether a newer authorized-fetch option exists was **[not seen]**.

## 2. HTTP signatures

1. Misskey signs outbound deliveries with draft-cavage only. Signed headers: `(request-target) date host digest`. There is no RFC 9421 signing. **[study]** `ApRequestService.ts`
2. Inbound, the `Signature` header is parsed with `@peertube/http-signature`. The signed headers must include `(request-target)`, `host`, and `date`. **[src]** `ActivityPubServerService.ts`
3. These cases answer 401: parse failure, `host` not signed, `Host` header different from the configured host, `digest` not signed, malformed `Digest`, an algorithm other than SHA-256, a body hash that does not match. **[src]** same file
4. A missing raw body gives 400. A body with no `actor` gives 400. **[src]** same file
5. Whether Misskey reads an RFC 9421 `Signature-Input` header on the inbox was **[not seen]**. A sender that signs only with RFC 9421 may be rejected at step 2 or 3. sukhi handles this with the fallback in [sukhi-0001](sukhi-0001-signature-fallback.md). **[sukhi]**
6. The allowed clock difference was **[not seen]**.

## 3. JSON-LD context

Misskey writes this `@context`: `https://www.w3.org/ns/activitystreams`, `https://w3id.org/security/v1`, and one inline term map. **[src]** `misc/contexts.ts`

| Term | Expands to |
| --- | --- |
| `Key` | `sec:Key` |
| `manuallyApprovesFollowers`, `sensitive`, `Hashtag`, `quoteUrl` | `as:` + the name |
| `toot` | `http://joinmastodon.org/ns#` |
| `Emoji`, `featured`, `discoverable` | `toot:` + the name |
| `schema` | `http://schema.org#` |
| `PropertyValue`, `value` | `schema:` + the name |
| `misskey` | `https://misskey-hub.net/ns#` |
| `_misskey_content`, `_misskey_quote`, `_misskey_reaction`, `_misskey_votes`, `_misskey_summary`, `_misskey_followedMessage`, `_misskey_requireSigninToViewContents`, `_misskey_makeNotesFollowersOnlyBefore`, `_misskey_makeNotesHiddenBefore`, `_misskey_license`, `isCat` | `misskey:` + the name |
| `freeText` | `misskey:freeText`, typed `schema:text` |
| `vcard` | `http://www.w3.org/2006/vcard/ns#` |

sukhi's own context defines `toot`, `misskey`, `sensitive`, `Hashtag`, `Emoji`, `_misskey_content`, `_misskey_quote`, and `quoteUrl` (at least; the list was read down to `_misskey_content`). **[sukhi]** `fedi/builders.ex:32-49`

## 4. Actor

What Misskey publishes for a user. **[src]** `ApRendererService.ts`, `renderPerson`

- `type` is `Application` when the user name contains a dot, `Service` when the user is a bot, and `Person` otherwise.
- Endpoints: `inbox`, `outbox`, `followers`, `following`, `featured`, `sharedInbox`, and `endpoints.sharedInbox`.
- `manuallyApprovesFollowers` comes from the locked flag. `discoverable` comes from the explorable flag.
- `publicKey` has the id fragment `#main-key`.
- Optional: `movedTo`, `alsoKnownAs`, `vcard:bday`, `vcard:Address`.
- `attachment` holds `PropertyValue` entries. A value that is an http(s) URL is wrapped in an anchor with `rel="me nofollow noopener"`.
- Misskey-only: `isCat`, `_misskey_summary`, `_misskey_followedMessage`, `_misskey_requireSigninToViewContents`, `_misskey_makeNotesFollowersOnlyBefore`, `_misskey_makeNotesHiddenBefore`.
- `speakAsCat` is **[not seen]**.

Reading: an actor is refreshed in the background when its stored data is older than 24 hours, after an activity from it is processed. **[src]** `ApInboxService.ts`

## 5. Note

### Sending **[src]** `ApRendererService.ts`, `renderNote`

- Fields: `id` (`/notes/{id}`), `type: "Note"`, `attributedTo`, `summary`, `content`, `published`, `inReplyTo`, `attachment`, `sensitive`, `tag`.
- `summary` is the content warning. An empty warning becomes a zero-width space.
- `sensitive` is true when a warning is set or any attached file is sensitive.
- `_misskey_content` and `source` (`mediaType: "text/x.misskeymarkdown"`) carry the MFM source. They are left out when the text has no MFM.
- `_misskey_quote` and `quoteUrl` both carry the URI of the quoted note. `quoteUri` and a tag `Link` are **[not seen]**.
- There is no `visibility` property. Visibility is only in `to` and `cc`.
- `tag` mixes `Hashtag`, `Mention`, and `Emoji` items. Emoji marked local-only are skipped.

### Addressing

| Visibility | `to` | `cc` |
| --- | --- | --- |
| public | Public collection | followers, plus mentioned remote users |
| home | followers | Public collection, plus mentioned remote users |
| followers | followers | mentioned remote users |
| direct | mentioned users | none |

**[study]** `ApRendererService.ts`. Misskey accepts three spellings of Public: the full IRI, `as:Public`, and `Public`. **[study]**

### Receiving **[src]** `models/ApNoteService.ts`

- Rejected: a type outside the accepted post types; an `id` or `attributedTo` whose host differs from the fetch host; a malformed `published`; a missing `id`; a non-HTTPS `id` or `url`; a missing `attributedTo`; a suspended actor; text with prohibited words; a host on the block list.
- Text is taken in this order: `source` with media type `text/x.misskeymarkdown`; then `_misskey_content`; then `content`, converted from HTML to MFM.
- Visibility is derived from `to` and `cc`. A note fetched by bare URI with no visible users is set to public.
- Each attachment's `sensitive` defaults to the note's `sensitive`.
- Emoji tags are saved. A failure there is logged and the note still saves.
- A reply to an unknown parent makes creation fail.
- A duplicate returns the existing note.

## 6. Quotes

- Misskey resolves a quote only from `_misskey_quote` or `quoteUrl`. **[src]** `ApNoteService.ts`
- It reads neither `quoteUri` nor a tag `Link` with a `rel`. **[src]** same file, **[not seen]** elsewhere. A FEP-e232 tag on its own is therefore not shown as a quote by Misskey.
- Candidates are resolved in parallel. If none resolves and any failure was temporary, creation fails with `quote resolve failed`. A permanent failure means the note is saved without the quote.
- sukhi sends `quoteUrl`, `_misskey_quote`, and the tag `Link`, so Misskey sees the first two. **[sukhi]** `fedi/builders.ex:347-364`. See [sukhi-0003](sukhi-0003-legacy-quote-profile.md).

## 7. Reactions

- Misskey sends a reaction as `Like` with `content` and `_misskey_reaction` both set to the reaction string. **[src]** `renderLike`
- A custom emoji gets one `Emoji` tag, only when the reaction starts with `:`, the emoji is in the local cache, and it is not local-only. **[src]** same function
- Misskey reads a reaction from `_misskey_reaction`, then `content`, then `name`. A second reaction by the same user on the same note is skipped (`already reacted`). **[src]** `ApInboxService.ts`
- A separate handler for `EmojiReact` was **[not seen]**. Whether `EmojiReact` reaches the `Like` path is unknown.
- sukhi sends `Like` with `content` and, for custom emoji, an `Emoji` tag. It does not set `_misskey_reaction`, which Misskey does not need because it falls back to `content`. **[sukhi]** `fedi/builders.ex:206-227`

## 8. Polls

- A poll in a note is written under `oneOf` or `anyOf`, chosen by whether multiple answers are allowed. Each choice is a `Note` with `name` and `replies`. The end is `endTime`, or `closed` when over. **[src]** `renderNote`
- A vote is a `Note` whose `name` matches a choice and whose `inReplyTo` is the poll. It is counted as a vote and no note is created. A vote on an expired poll is skipped. **[src]** `ApNoteService.ts`
- Updated counts travel as `Update` of a `Question`, with `_misskey_votes` per choice. **[src]** `renderQuestion`, `ApInboxService.ts`
- sukhi's vote has the same shape: a `Create(Note)` with `name`, `inReplyTo`, and `to` set to the poll author. **[sukhi]** `fedi/builders.ex` (`vote/1`)

## 9. Activities accepted at the inbox **[src]** `ApInboxService.ts`

| Type | What Misskey does |
| --- | --- |
| Create | Creates a `Post` only. `attributedTo` must equal the actor and the note id must share the actor's host. `bear:` URIs are skipped. |
| Delete | The target type comes from `object.type`, or a Tombstone's `formerType`. A bare string has no known type. With no type, an object equal to the actor is a `Person`, otherwise a `Note`. A note is deleted only if the actor owns it. An actor is marked deleted and a deletion job is queued. |
| Update | Only actors and `Question`. Anything else is skipped. A `Note` update is therefore not applied. |
| Follow | The target must be a local user. It is handled at once. |
| Accept, Reject | Only for `Follow`. Follow ids containing `follow-relay/` go to relay logic. |
| Undo | Follow, Block, Like, Announce, Accept. Others are skipped. |
| Like | See section 7. |
| Announce | The target must be a post and visible to the actor. Relay announces publish the note directly. A malformed `published` is rejected. |
| Block | The target must be a local user. |
| Flag | Collects `/users/` URIs, takes the first local user as the target, and puts the content in the report comment. |
| Move | Needs a target `href`; otherwise the actor is refreshed. |
| Add, Remove | Only pin and unpin, when the target is the actor's `featured` collection. |
| anything else | `unrecognized activity type`. |

Other rules from the same file:
- A suspended actor is ignored.
- A `Collection` or `OrderedCollection` is unpacked item by item. Items whose host differs from the actor's are skipped.

Consequence for sukhi: an edit sent as `Update(Note)` is probably not applied by Misskey. **[study]**, not tested on a live server. sukhi sends `Update(Note)` on edit. **[study]** `outbox/consumer.ex`

## 10. Collections **[src]** `ActivityPubServerService.ts`

| Endpoint | Page size | Paging | Limits |
| --- | --- | --- | --- |
| outbox `/users/:user/outbox` | 20 | `since_id`, `until_id` | public and home notes that are not local-only |
| followers, following | 10 | `cursor` | 403 when the user's visibility is `followers` or `private` |
| featured `/users/:user/collections/featured` | all | none | public and home notes that are not local-only |

Note: the featured path is `/users/:user/collections/featured`, not `/users/:user/featured`. sukhi serves `/users/:name/featured`. **[sukhi]** `web/router.ex:306`. A sukhi reader that builds Misskey's featured URL from the actor document will use the `featured` property, so this only matters to a reader that guesses paths.

## 11. Delivery behaviour **[study]**

- Misskey groups followers by shared inbox and falls back to the personal inbox.
- Retries: BullMQ, 12 attempts by default, delay `(2^n - 1)` minutes up to 8 hours, about 1.3 days in total (calculated).
- Misskey does not retry most 4xx answers, except 429. It stops delivering to a server that answers 410 on a shared inbox, and to a server that has not answered for one week.
- For sukhi, which retries for about 20 minutes (calculated), a short outage on the Misskey side can drop a delivery.

## 12. What sukhi relies on, in one table

| Need | Misskey behaviour | sukhi action | Where |
| --- | --- | --- | --- |
| Accept our signature | cavage, with digest and host signed | falls back to cavage on 400/401 | sukhi-0001 |
| Show our quote | reads `_misskey_quote`, `quoteUrl` | sends both and the tag `Link` | sukhi-0003 |
| Show our reaction | reads `_misskey_reaction`, `content`, `name` | sends `Like` with `content` | `builders.ex:206` |
| Show our formatting | reads `_misskey_content`, `source` | reads and keeps MFM; sends `_misskey_content` | `extract.ex`, `builders.ex` |
| Keep our edits | applies `Update` of actors and `Question` only | sends `Update(Note)`; likely not applied | gap |
| Keep our public notes public | accepts three spellings of Public | sends the full IRI | `audience.ex` |
| Count our poll votes | counts a `Note` with matching `name` | sends that shape | `builders.ex` |

## 13. Not researched

- WebFinger and NodeInfo output of Misskey.
- Misskey's inbound clock window and its authorized-fetch option.
- The handling of `EmojiReact`.
- The `Accept`/`Reject` side for follow requests of locked accounts.
- Media (`attachment`) limits.
- Behaviour of forks.
- Any behaviour that changed on `develop` after 2026-10-23.
