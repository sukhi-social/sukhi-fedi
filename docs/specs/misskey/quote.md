<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Quotes

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `#Quote`, defined below

## In one paragraph

Misskey recognises a quote only from two properties, `_misskey_quote` and `quoteUrl`. It does not read a FEP-e232 `tag` `Link`, and it does not read `quoteUri`. A server that wants Misskey to show a quote has to send one of the two.

## What Misskey does **[src]** `ApNoteService.ts`

- A quote is resolved only when `_misskey_quote` or `quoteUrl` is present.
- The candidate URIs are made unique and resolved in parallel. A value that is not http(s), or a permanent failure (not found, not retryable), counts as failed for good.
- The first success becomes the quote.
- If none succeeds and any failure was temporary, creation fails with `quote resolve failed`. If every failure was permanent, the note is saved without the quote.

## An example

The quote part of a note (type `#Quote`):
```json
{
  "type": "Note",
  "content": "<p>Look at this</p>",
  "quoteUrl": "https://other.example/notes/1",
  "_misskey_quote": "https://other.example/notes/1"
}
```

The type, in [CUE](https://cuelang.org):

```cue
// The quote properties of a Note as Misskey writes and reads them: either
// one, or both. They hold the URL of the quoted note.
#Quote: {
	quoteUrl:          #URL
	"_misskey_quote"?: #URL
	...
} | {
	"_misskey_quote": #URL
	quoteUrl?:        #URL
	...
}
```

## Things to watch

- If the quoted note cannot be fetched temporarily, Misskey refuses the whole note (and does not save it). A later delivery has to succeed.
