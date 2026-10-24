<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: its own terms

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

Misskey adds its own terms to ActivityPub. Three matter to anyone who talks to it: `_misskey_content` (the MFM source of a note), `_misskey_quote` with `quoteUrl` (a quote), and `_misskey_reaction` (the string of a reaction). The rest describe profile settings and can be ignored by a server that does not draw them.

All the terms live in the `misskey:` namespace, `https://misskey-hub.net/ns#`, except `quoteUrl` (`as:quoteUrl`). **[src]** `misc/contexts.ts`

A meaning marked *name only* is a guess from the term's name: the code that writes or reads it was not opened.

## Notes

| Term | What Misskey does with it |
| --- | --- |
| `_misskey_content` | MFM source of the note. Sent only when the text has MFM beyond plain nodes; read before `content`. See [mfm](mfm.md). |
| `source` (`text/x.misskeymarkdown`) | the same source in the AS2 form; read first. |
| `_misskey_quote`, `quoteUrl` | URI of the quoted note; the only two quote forms Misskey reads. See [quote](quote.md). |
| `_misskey_reaction` | the reaction string on a `Like`, set together with `content`. See [reactions](reactions.md). |
| `_misskey_votes` | vote count of a poll choice, in a `Question`. See [poll](poll.md). |
| `_misskey_license` | *name only*: a licence for a file or emoji. |
| `sensitive` | `as:sensitive`; true when a content warning is set or a file is sensitive. |

## Actors

| Term | What Misskey does with it |
| --- | --- |
| `isCat` | a flag on the actor **[src]** `renderPerson` (meaning: *name only*, a "cat" account). |
| `_misskey_summary` | *name only*: the profile text as plain MFM source. |
| `_misskey_followedMessage` | *name only*: a message shown after a follow. |
| `_misskey_requireSigninToViewContents` | *name only*: the user's notes need sign-in to view. |
| `_misskey_makeNotesFollowersOnlyBefore`, `_misskey_makeNotesHiddenBefore` | *name only*: time-based limits on old notes. |
| `featured` (`toot:featured`), `discoverable` (`toot:discoverable`) | Mastodon terms that Misskey also uses. |
| `vcard:bday`, `vcard:Address` | optional birthday and address on the actor. |
| `freeText` | *name only*. |

## Outside ActivityPub

| Item | What Misskey does |
| --- | --- |
| Avatar decorations | not in the actor document. Returned by Misskey's own API, `POST /api/users/show`, as `avatarDecorations`. |
| Client API | Misskey's own HTTP API, not covered here. |

## How to tell that an actor is from Misskey

The `@context` of a Misskey actor contains an object with a `misskey` key (see [json-ld-context](json-ld-context.md)). A fork that omits the term cannot be told apart this way.

## Things to watch

- Misskey ignores FEP-8b32 proofs and checks the HTTP signature, so these terms do not need to be covered by a proof. See [signatures](signatures.md).
- The values are text written by users. Treat them as untrusted.
