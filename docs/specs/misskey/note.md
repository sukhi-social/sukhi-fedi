<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Note

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Type: `#Note` (what Misskey writes) and `#InNote` (what it reads), defined in [objects](objects.md)

## In one paragraph

Misskey writes a normal `Note` with a few extra properties for MFM source and quotes, and reads one strictly: the note's `id` and `attributedTo` must be on the host it was fetched from, and the sender must be the author. Visibility is not a property; it is read from `to` and `cc`.

## Sending **[src]** `ApRendererService.ts`, `renderNote`

Every property Misskey writes is in `#Note`. Points that the type cannot show:

- `summary` is the content warning. An empty warning becomes a zero-width space (U+200B).
- `sensitive` is true when a warning is set or any attached file is sensitive.
- `_misskey_content` and `source` carry the MFM source; see [mfm](mfm.md) for when they are present. `_misskey_quote` and `quoteUrl` carry the quoted note's URI; see [quote](quote.md).
- There is no `visibility` property, and no `url`.
- `tag` mixes `Hashtag`, `Mention`, and `Emoji` items. Emoji marked local-only are skipped.
- A poll makes the note a `Question`; see [poll](poll.md).

### Addressing

In the table, *Public* is the IRI `https://www.w3.org/ns/activitystreams#Public`, *followers* is `<actor>/followers`, and *mentioned* are the remote users mentioned in the text.

| Visibility | `to` | `cc` |
| --- | --- | --- |
| public | Public | followers, mentioned |
| home | followers | Public, mentioned |
| followers | followers | mentioned |
| direct | mentioned | none |

## Receiving

### Which notes are refused **[src]** `models/ApNoteService.ts`

A note is refused when:
- its type is not an accepted post type (`Note`, `Question`, `Article`, `Audio`, `Document`, `Image`, `Page`, `Video`, `Event`);
- its `id` or `attributedTo` is on a different host from the one it was fetched from, or `attributedTo` is not the sending actor;
- `published` is malformed;
- `id` is missing, or `id` or `url` is not https;
- the actor is suspended;
- the text contains prohibited words;
- the host is on the block list.

### What is kept when it is accepted **[src]** same file

- The text is taken from `source`, `_misskey_content`, or `content` in that order ([mfm](mfm.md)).
- Visibility comes from `to` and `cc` (next section). A note Misskey fetched by its bare URI, and would otherwise make "direct" with no recipients, is made public.
- Each attachment's `sensitive` defaults to the note's `sensitive`.
- Emoji tags are saved. A failure there is logged, and the note is saved anyway.
- A reply to a parent Misskey cannot find makes creation fail.
- A duplicate returns the existing note.

### Visibility from `to` and `cc` **[src]** `ApAudienceService.ts`

Misskey reads the ids in `to` and `cc` and sorts each into Public, the actor's followers collection, or other. Public is any of `https://www.w3.org/ns/activitystreams#Public`, `as:Public`, and `Public`. The followers collection is the actor's `followers` URL, or `<actor>/followers` if it has none. The first row that matches decides:

| If | Visibility |
| --- | --- |
| Public is in `to` | public |
| Public is in `cc` | home |
| the followers collection is in `to` or `cc` | followers |
| none of the above | direct; the other ids that are users are the recipients |

## Things to watch

- A note whose `id` is on another host than the one Misskey fetched it from is refused.
- `https` is required for `id` and `url`.
- A reply to a note that Misskey cannot find fails on the Misskey side.
