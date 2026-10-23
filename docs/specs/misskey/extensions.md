<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: its own extensions and how to support them

- Kind: descriptive (what Misskey does), with a column on how sukhi supports each item. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

Every Misskey-only term, one row each. All of them live in the `misskey:` namespace, `https://misskey-hub.net/ns#`, except `quoteUrl` (`as:quoteUrl`). **[src]** `misc/contexts.ts`

How to read the columns:
- **Misskey** says what was read. A meaning marked *name only* is a guess from the term's name. The code that writes or reads it was not opened.
- **sukhi** says what the sukhi code does today.
- **Handling** is a suggestion for sukhi, not a statement about Misskey.

## Notes

| Term | Misskey | sukhi | Handling |
| --- | --- | --- | --- |
| `_misskey_content` | MFM source of the note. Sent only when the text has MFM beyond plain nodes; read before `content`. See [mfm](mfm.md). | read and stored; sent on every note | keep both directions |
| `source` (`text/x.misskeymarkdown`) | the same source in the AS2 form; read first | read (media type not checked); not sent | check the media type; add on send |
| `_misskey_quote`, `quoteUrl` | URI of the quoted note; the only two quote forms Misskey reads. See [quote](quote.md). | read and sent | keep both until [sukhi-0003](../sukhi-0003-legacy-quote-profile.md) ends them |
| `_misskey_reaction` | the reaction string on a `Like`, set together with `content`. See [reactions](reactions.md). | not sent; read **[not seen]** | read it first, then `content`, as Misskey does |
| `_misskey_votes` | vote count of a poll choice, in a `Question`. See [poll](poll.md). | **[not seen]** | read it if poll results from Misskey are to be shown |
| `_misskey_license` | *name only*: a licence for a file or emoji | **[not seen]** | ignore |
| `sensitive` | `as:sensitive`; true when a content warning is set or a file is sensitive | read and sent | keep |

## Actors

| Term | Misskey | sukhi | Handling |
| --- | --- | --- | --- |
| `isCat` | a flag on the actor **[src]** `renderPerson` (meaning: *name only*, a "cat" account) | not used | ignore, or show a marker |
| `_misskey_summary` | *name only*: the profile text as plain MFM source | not used | read like `_misskey_content` if profile MFM is wanted |
| `_misskey_followedMessage` | *name only*: a message shown after a follow | not used | ignore |
| `_misskey_requireSigninToViewContents` | *name only*: the user's notes need sign-in to view | not used | ignore; sukhi's own notes have no such mode |
| `_misskey_makeNotesFollowersOnlyBefore`, `_misskey_makeNotesHiddenBefore` | *name only*: time-based limits on old notes | not used | ignore |
| `featured` (`toot:featured`), `discoverable` (`toot:discoverable`) | Mastodon terms that Misskey also uses | sent | keep |
| `vcard:bday`, `vcard:Address` | optional birthday and address on the actor | not used | ignore |
| `freeText` | *name only* | not used | ignore |

## Outside ActivityPub

| Item | Misskey | sukhi | Handling |
| --- | --- | --- | --- |
| Avatar decorations | not in the actor document. Returned by Misskey's own API, `POST /api/users/show`, as `avatarDecorations` | read by a background job only for actors whose `@context` has a `misskey` term; stored; drawn over the icon; the web client uses `/proxy/deco/:id/:n` so the viewer's address does not reach the origin. Silent on failure. (`federation/misskey_decorations.ex`, `federation/remote_accounts.ex`) | keep as is: it is best effort, and it depends on a non-standard API |
| Misskey client API | not covered here | a plan only (`docs/MISSKEY_API.md`) | none |

## How sukhi tells that an actor is from the Misskey family

`misskey_family?/1` is true when the `@context` of the actor contains an object with a `misskey` key. (`federation/remote_accounts.ex`) This is a sound test for Misskey and forks that write the standard context. A fork that omits the term would not be found.

## Rule of thumb for any extension

1. Reading: take it when it is present, and fall back to the standard property when it is not.
2. Showing: treat the value as untrusted text. Escape first.
3. Writing: send it only if Misskey reads it (the table above) and the standard property is also correct. Never make the standard property depend on it.
4. Sign: Misskey ignores FEP-8b32 proofs and checks the HTTP signature, so extension terms do not need to be covered by a proof. See [signatures](signatures.md).
