<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Actor

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

A Misskey user is a normal ActivityPub actor with a few Misskey-only properties. A server that ignores the extra properties still gets everything it needs to follow, deliver to, and show the user.

## What Misskey publishes **[src]** `ApRendererService.ts`, `renderPerson`

- `type` is `Application` when the user name contains a dot, `Service` for a bot, and `Person` otherwise.
- Endpoints: `inbox`, `outbox`, `followers`, `following`, `featured`, `sharedInbox`, and `endpoints.sharedInbox`.
- `manuallyApprovesFollowers` comes from the locked flag. `discoverable` comes from the explorable flag.
- `publicKey` has the id fragment `#main-key`.
- Optional: `movedTo`, `alsoKnownAs`, `vcard:bday`, `vcard:Address`.
- `attachment` holds `PropertyValue` entries. A value that is an http(s) URL is wrapped in an anchor with `rel="me nofollow noopener"`.
- Misskey-only: `isCat`, `_misskey_summary`, `_misskey_followedMessage`, `_misskey_requireSigninToViewContents`, `_misskey_makeNotesFollowersOnlyBefore`, `_misskey_makeNotesHiddenBefore`. What each means is in [extensions](extensions.md).
- `speakAsCat` was **[not seen]**.

## How Misskey reads an actor

An actor is fetched again in the background when its stored data is older than 24 hours, after an activity from it has been processed. **[src]** `ApInboxService.ts`

## What sukhi does **[sukhi]**

sukhi tells that an actor comes from the Misskey family when its `@context` has an object with a `misskey` key. It then asks Misskey's own API for avatar decorations (see [extensions](extensions.md)). sukhi does not use `isCat` or the other `_misskey_*` actor properties.
