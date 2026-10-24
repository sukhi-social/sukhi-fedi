<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: JSON-LD context

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

Every object Misskey sends starts with an `@context`. It is the two standard contexts plus one inline list of extra terms. Those terms are what make `_misskey_content`, `isCat`, and the rest mean something.

## What Misskey writes **[src]** `misc/contexts.ts`

The context is `https://www.w3.org/ns/activitystreams`, `https://w3id.org/security/v1`, and one term map:

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

## Things to watch

A term that is not in the `@context` is dropped when the document is expanded as JSON-LD. A Linked-Data signature is made over the expanded document, so a term missing from the context is not covered by it. See also [extensions](extensions.md).
