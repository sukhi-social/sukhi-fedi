<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Note

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

Misskey writes a normal `Note` with a few extra properties for MFM source and quotes. When it reads a note, it is strict about who may speak for whom: the note's `id` and `attributedTo` must be on the same host as the fetch.

## Sending **[src]** `ApRendererService.ts`, `renderNote`

- Fields: `id` (`/notes/{id}`), `type: "Note"`, `attributedTo`, `summary`, `content`, `published`, `inReplyTo`, `attachment`, `sensitive`, `tag`.
- `summary` is the content warning. An empty warning becomes a zero-width space.
- `sensitive` is true when a warning is set or any attached file is sensitive.
- `_misskey_content` and `source` carry the MFM source. They are left out when the text has no MFM. See [mfm](mfm.md).
- `_misskey_quote` and `quoteUrl` carry the quoted note's URI. See [quote](quote.md). `quoteUri` and a tag `Link` were **[not seen]**.
- There is no `visibility` property. Visibility is only in `to` and `cc`.
- `tag` mixes `Hashtag`, `Mention`, and `Emoji` items. Emoji marked local-only are skipped.

### Addressing **[study]** `ApRendererService.ts`

| Visibility | `to` | `cc` |
| --- | --- | --- |
| public | Public collection | followers, plus mentioned remote users |
| home | followers | Public collection, plus mentioned remote users |
| followers | followers | mentioned remote users |
| direct | mentioned users | none |

Misskey accepts three spellings of Public: the full IRI, `as:Public`, and `Public`. **[study]**

## Receiving **[src]** `models/ApNoteService.ts`

A note is **refused** when:
- its type is not an accepted post type;
- its `id` or `attributedTo` is on a different host from the one it was fetched from;
- `published` is malformed;
- `id` is missing or `id`/`url` is not HTTPS;
- `attributedTo` is missing, or the actor is suspended;
- the text contains prohibited words;
- the host is on the block list.

When it is accepted:
- Text is taken in this order: `source` (media type `text/x.misskeymarkdown`); `_misskey_content`; `content` converted from HTML. Details in [mfm](mfm.md).
- Visibility is derived from `to` and `cc`. A note fetched by bare URI that would have no visible users is made public.
- Each attachment's `sensitive` defaults to the note's `sensitive`.
- Emoji tags are saved. A failure there is logged, and the note is saved anyway.
- A reply to an unknown parent makes creation fail.
- A duplicate returns the existing note.

## What it means for sukhi

- A note whose `id` is on another host than the one Misskey fetched it from is refused. sukhi's note ids are on its own domain. **[sukhi]**
- `https` is required for `id` and `url`.
- A reply from sukhi to a Misskey note that Misskey cannot find fails on the Misskey side.
