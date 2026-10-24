<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: JSON-LD context

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

Every object Misskey sends starts with an `@context`. It is the two standard contexts plus one inline list of extra terms. Those terms are what make `_misskey_content`, `isCat`, and the rest mean something. sukhi writes its own `@context`, which defines the terms sukhi uses.

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

## What sukhi does **[sukhi]** `fedi/builders.ex:32-49`

sukhi's context has the two standard contexts, the data-integrity context (for FEP-8b32 proofs), `https://gotosocial.org/ns` (for interaction policies), and a term map that defines at least `toot`, `misskey`, `sensitive`, `Hashtag`, `Emoji`, `_misskey_content`, `_misskey_quote`, and `quoteUrl`. The map was read down to `_misskey_content`.

## Why it matters

A term that is not in the `@context` is dropped when the document is expanded as JSON-LD. sukhi signs with Linked Data signatures, which expand the document, so a term missing from the context would not be covered by the signature. This is why sukhi defines every term it injects. See also [extensions](extensions.md).
