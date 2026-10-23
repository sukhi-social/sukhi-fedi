<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Activities accepted at the inbox

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

Source of this page: **[src]** `ApInboxService.ts`

| Type | What Misskey does |
| --- | --- |
| Create | Creates a `Post` only. `attributedTo` must equal the actor and the note id must share the actor's host. `bear:` URIs are skipped. |
| Delete | The target type comes from `object.type`, or a Tombstone's `formerType`. A bare string has no known type. With no type, an object equal to the actor is a `Person`, otherwise a `Note`. A note is deleted only if the actor owns it. An actor is marked deleted and a deletion job is queued. |
| Update | Only actors and `Question`. Anything else is skipped. A `Note` update is therefore not applied. |
| Follow | The target must be a local user. It is handled at once. |
| Accept, Reject | Only for `Follow`. Follow ids containing `follow-relay/` go to relay logic. |
| Undo | Follow, Block, Like, Announce, Accept. Others are skipped. |
| Like | See [reactions](reactions.md). |
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
