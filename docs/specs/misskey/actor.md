<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Actor

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Type: `#Person` (what Misskey writes) and `#InActor` (what it reads), defined in [objects](objects.md)

## In one paragraph

A Misskey user is a normal ActivityPub actor with a few Misskey-only properties. A server that ignores the extra properties still gets everything it needs to follow, deliver to, and show the user. The actor is found by WebFinger ([webfinger](webfinger.md)) and served at `/users/<id>` ([transport](transport.md)).

## What Misskey publishes **[src]** `ApRendererService.ts`, `renderPerson`

Every property is in `#Person`. Points that the type cannot show:

- `type` is `Application` when the user name contains a dot (a system account), `Service` for a bot, and `Person` otherwise.
- `manuallyApprovesFollowers` is the locked flag; `discoverable` is the explorable flag. A locked account does not accept every follow at once ([activities-received](activities-received.md#following-step-by-step)).
- The key's id is `<actor>#main-key`.
- `attachment` holds `PropertyValue` entries (profile fields). A value that is an http(s) URL is wrapped in an anchor with `rel="me nofollow noopener"`.
- The Misskey-only properties are explained in [extensions](extensions.md). `speakAsCat` was **[not seen]**.

## How Misskey reads an actor

**[src]** `ApPersonService.ts`, `ApInboxService.ts`

- The type must be `Person`, `Service`, `Group`, `Organization`, or `Application`. `id`, `inbox`, and `preferredUsername` are required; the rest in `#InActor` is optional.
- `id`, `inbox`, `outbox`, `followers`, `following`, and `publicKey.id` must be on the host the actor was fetched from. A shared inbox on another host is dropped, not an error.
- `preferredUsername` is word characters, dots, and hyphens, up to 128 characters. `name` and `summary` are cut when long.
- `Service` and `Application` count as bots.
- An actor is fetched again in the background when its stored data is older than 24 hours, after an activity from it has been processed.
- Misskey reads the settings `isCat`, `requireSigninToViewContents`, `makeNotesFollowersOnlyBefore`, and `makeNotesHiddenBefore` without the `_misskey_` prefix that it writes them with ([objects](objects.md)).
