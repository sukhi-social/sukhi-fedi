<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Quotes

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `QuoteNote`, defined below

## In one paragraph

Misskey recognises a quote only from two properties, `_misskey_quote` and `quoteUrl`. It does not read a FEP-e232 `tag` `Link`, and it does not read `quoteUri`. A server that wants Misskey to show a quote has to send one of the two.

## What Misskey does **[src]** `ApNoteService.ts`

- A quote is resolved only when `_misskey_quote` or `quoteUrl` is present.
- The candidate URIs are made unique and resolved in parallel. A value that is not http(s), or a permanent failure (not found, not retryable), counts as failed for good.
- The first success becomes the quote.
- If none succeeds and any failure was temporary, creation fails with `quote resolve failed`. If every failure was permanent, the note is saved without the quote.

## What sukhi does **[sukhi]** `fedi/builders.ex:347-364`

sukhi sends all three forms ([sukhi-0003](../sukhi-0003-legacy-quote-profile.md)), so Misskey finds the first two. On the receiving side sukhi reads all of them, including a tag `Link` and `quoteUri` (`ap/instructions/extract.ex`).

A quote as sukhi sends it (type `QuoteNote`):
```json
{
  "type": "Note",
  "content": "<p>Look at this</p>",
  "quoteUrl": "https://remote.example/notes/1",
  "_misskey_quote": "https://remote.example/notes/1",
  "tag": [
    {
      "type": "Link",
      "href": "https://remote.example/notes/1",
      "rel": "_misskey_quote"
    }
  ]
}
```

The type, written as JSDoc so the page can be read on its own (the checker compiles it):

```js
/**
 * A Note that quotes another post: the three forms of sukhi-0003 "Sending".
 * Other properties of a Note are allowed.
 * @typedef {{[other: string]: unknown, type: 'Note' | 'Article', quoteUrl: string, _misskey_quote: string, tag: [object, ...object[]]}} QuoteNote
 * `quoteUrl` and `_misskey_quote` are both the URL of the quoted post. At
 * least one `tag` entry is `{type: 'Link', href: <that URL>, rel: '_misskey_quote'}`;
 * this check does not look for it.
 */
```

## Things to watch

- If the quoted note cannot be fetched temporarily, Misskey refuses the whole note (and does not save it). A later delivery has to succeed.
- The Misskey rule that a quote is read only from two properties is why sukhi keeps sending them until Misskey also reads `quote` (FEP-044f). Whether it will was not researched.
