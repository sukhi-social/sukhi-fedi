<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Actor

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

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
