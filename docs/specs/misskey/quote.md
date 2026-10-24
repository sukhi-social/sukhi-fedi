<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Quotes

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Schema: `schemas/quote-note.schema.json`

## In one paragraph

Misskey recognises a quote only from two properties, `_misskey_quote` and `quoteUrl`. It does not read a FEP-e232 `tag` `Link`, and it does not read `quoteUri`. A server that wants Misskey to show a quote has to send one of the two.

## What Misskey does **[src]** `ApNoteService.ts`

- A quote is resolved only when `_misskey_quote` or `quoteUrl` is present.
- The candidate URIs are made unique and resolved in parallel. A value that is not http(s), or a permanent failure (not found, not retryable), counts as failed for good.
- The first success becomes the quote.
- If none succeeds and any failure was temporary, creation fails with `quote resolve failed`. If every failure was permanent, the note is saved without the quote.

## What sukhi does **[sukhi]** `fedi/builders.ex:347-364`

sukhi sends all three forms ([sukhi-0003](../sukhi-0003-legacy-quote-profile.md)), so Misskey finds the first two. On the receiving side sukhi reads all of them, including a tag `Link` and `quoteUri` (`ap/instructions/extract.ex`).

A quote as sukhi sends it ([quote-note schema](../schemas/quote-note.schema.json)):
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

The schema, copied here so the page can be read on its own:

<!-- schema: quote-note.schema.json -->
```json
{
  "$schema": "http://json-schema.org/draft-04/schema#",
  "id": "https://sukhi.social/spec/schemas/quote-note.schema.json",
  "$comment": "SPDX-License-Identifier: AGPL-3.0-or-later",
  "title": "Note carrying a quote (sukhi-0003)",
  "description": "The quote properties a sukhi Note carries when it quotes another post: the three forms of sukhi-0003 'Sending'. Other properties of a Note are not restricted here.",
  "type": "object",
  "required": [
    "type",
    "quoteUrl",
    "_misskey_quote",
    "tag"
  ],
  "properties": {
    "type": {
      "enum": [
        "Note",
        "Article"
      ]
    },
    "quoteUrl": {
      "type": "string",
      "format": "uri",
      "description": "URL of the quoted post."
    },
    "_misskey_quote": {
      "type": "string",
      "format": "uri",
      "description": "The same URL."
    },
    "tag": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object"
      },
      "description": "At least one entry is {\"type\":\"Link\",\"href\":<the quoted URL>,\"rel\":\"_misskey_quote\"}. Draft-04 has no `contains`, so that part is stated here, not checked."
    }
  }
}
```

## Things to watch

- If the quoted note cannot be fetched temporarily, Misskey refuses the whole note (and does not save it). A later delivery has to succeed.
- The Misskey rule that a quote is read only from two properties is why sukhi keeps sending them until Misskey also reads `quote` (FEP-044f). Whether it will was not researched.
