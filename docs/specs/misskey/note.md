<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Note

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

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
- Text is taken in this order (details in [mfm.md](mfm.md)): `source` with media type `text/x.misskeymarkdown`; then `_misskey_content`; then `content`, converted from HTML to MFM.
- Visibility is derived from `to` and `cc`. A note fetched by bare URI with no visible users is set to public.
- Each attachment's `sensitive` defaults to the note's `sensitive`.
- Emoji tags are saved. A failure there is logged and the note still saves.
- A reply to an unknown parent makes creation fail.
- A duplicate returns the existing note.
