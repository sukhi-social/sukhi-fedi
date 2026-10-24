<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Polls

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Schema: `schemas/poll-vote.schema.json`

## In one paragraph

A poll is a `Question`-like note whose choices are listed under `oneOf` or `anyOf`. A vote is a tiny `Note` whose `name` is the chosen option and which replies to the poll. Misskey counts such a note as a vote and does not create a note. sukhi sends votes in the same shape.

## What Misskey does

- A poll in a note is written under `oneOf` (one answer) or `anyOf` (several). Each choice is a `Note` with `name` and `replies`. The end is `endTime`, or `closed` when over. **[src]** `renderNote`
- A vote is a `Note` whose `name` matches a choice and whose `inReplyTo` is the poll. It is counted and no note is created. A vote on an expired poll is skipped. **[src]** `ApNoteService.ts`
- New counts travel as an `Update` of a `Question`, with `_misskey_votes` on each choice. **[src]** `renderQuestion`, `ApInboxService.ts`

## What sukhi does **[sukhi]** `fedi/builders.ex` (`vote/1`)

A vote is a `Create` of a `Note` that has `name`, `inReplyTo`, and `to` set to the poll's author. It has no `content` and no `cc`.

A vote as sukhi sends it ([poll-vote schema](../schemas/poll-vote.schema.json)):
```json
{
  "type": "Create",
  "actor": "https://sukhi.social/users/hina",
  "to": [
    "https://remote.example/users/a"
  ],
  "object": {
    "type": "Note",
    "attributedTo": "https://sukhi.social/users/hina",
    "name": "Option 2",
    "inReplyTo": "https://remote.example/notes/9",
    "to": [
      "https://remote.example/users/a"
    ]
  }
}
```

The schema, copied here so the page can be read on its own:

<!-- schema: poll-vote.schema.json -->
```json
{
  "$schema": "http://json-schema.org/draft-04/schema#",
  "id": "https://sukhi.social/spec/schemas/poll-vote.schema.json",
  "$comment": "SPDX-License-Identifier: AGPL-3.0-or-later",
  "title": "Poll vote (Create of a Note)",
  "description": "Descriptive and sent by sukhi: a vote is a Create of a small Note whose `name` is the chosen option and whose `inReplyTo` is the poll. Misskey counts a Note with a matching `name` as a vote and creates no note (see misskey/poll.md).",
  "type": "object",
  "required": [
    "type",
    "actor",
    "object"
  ],
  "properties": {
    "type": {
      "enum": [
        "Create"
      ]
    },
    "actor": {
      "type": "string",
      "format": "uri"
    },
    "to": {
      "type": "array",
      "items": {
        "type": "string",
        "format": "uri"
      },
      "minItems": 1
    },
    "object": {
      "type": "object",
      "required": [
        "type",
        "attributedTo",
        "name",
        "inReplyTo"
      ],
      "properties": {
        "type": {
          "enum": [
            "Note"
          ]
        },
        "attributedTo": {
          "type": "string",
          "format": "uri"
        },
        "name": {
          "type": "string",
          "minLength": 1
        },
        "inReplyTo": {
          "type": "string",
          "format": "uri"
        },
        "content": {
          "not": {}
        },
        "cc": {
          "not": {}
        }
      }
    }
  }
}
```

## Not researched

Whether sukhi reads `_misskey_votes`; how sukhi shows updated counts from Misskey.
