<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Quotes

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Type: `#Note`, defined in [objects](objects.md) (`quoteUrl` and `_misskey_quote` are two of its properties)

## In one paragraph

Misskey recognises a quote only from two properties, `_misskey_quote` and `quoteUrl`. It does not read a FEP-e232 `tag` `Link`, and it does not read `quoteUri`. A server that wants Misskey to show a quote has to send one of the two.

## What Misskey does **[src]** `ApNoteService.ts`

- A quote is resolved only when `_misskey_quote` or `quoteUrl` is present.
- The candidate URIs are made unique and resolved in parallel. A value that is not http(s), or a permanent failure (not found, not retryable), counts as failed for good.
- The first success becomes the quote.
- If none succeeds and any failure was temporary, creation fails with `quote resolve failed`. If every failure was permanent, the note is saved without the quote.

## What Misskey writes **[src]** `renderNote`

When a note quotes (renotes with text) another, Misskey writes the quoted note's URI into both `_misskey_quote` and `quoteUrl`, and appends a line to the `content` HTML: `<br><br><span class="quote-inline">RE: <a href="URI">URI</a></span>`. The class name `quote-inline` is there so that other servers can style the quote. Because `content` is then not plain, the MFM source is sent as well ([mfm](mfm.md)).

A quoting note (type `#Note`):
```json
{
  "id": "https://misskey.example/notes/9abf",
  "type": "Note",
  "attributedTo": "https://misskey.example/users/a1",
  "content": "<p>Look at this</p><br><br><span class=\"quote-inline\">RE: <a href=\"https://other.example/notes/1\">https://other.example/notes/1</a></span>",
  "_misskey_content": "Look at this",
  "source": {
    "content": "Look at this",
    "mediaType": "text/x.misskeymarkdown"
  },
  "_misskey_quote": "https://other.example/notes/1",
  "quoteUrl": "https://other.example/notes/1",
  "published": "2026-10-23T09:15:00.000Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://misskey.example/users/a1/followers"],
  "inReplyTo": null,
  "attachment": [],
  "sensitive": false,
  "tag": []
}
```

## Things to watch

- If the quoted note cannot be fetched temporarily, Misskey refuses the whole note (and does not save it). A later delivery has to succeed.
