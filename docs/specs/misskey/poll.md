<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Polls

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `#Vote`, defined in [activities](activities.md)

## In one paragraph

A poll is a `Question`-like note whose choices are listed under `oneOf` or `anyOf`. A vote is a tiny `Note` whose `name` is the chosen option and which replies to the poll. Misskey counts such a note as a vote and does not create a note.

## What Misskey does

- A poll in a note is written under `oneOf` (one answer) or `anyOf` (several). Each choice is a `Note` with `name` and `replies`. The end is `endTime`, or `closed` when over. **[src]** `renderNote`
- A vote is a `Note` whose `name` matches a choice and whose `inReplyTo` is the poll. It is counted and no note is created. A vote on an expired poll is skipped. **[src]** `ApNoteService.ts`
- New counts travel as an `Update` of a `Question`, with `_misskey_votes` on each choice. **[src]** `renderQuestion`, `ApInboxService.ts`

## An example

A vote (type `#Vote`):
```json
{
  "id": "https://misskey.example/users/a1#votes/v1/activity",
  "type": "Create",
  "actor": "https://misskey.example/users/a1",
  "to": ["https://other.example/users/b2"],
  "published": "2026-10-23T09:40:00.000Z",
  "object": {
    "id": "https://misskey.example/users/a1#votes/v1",
    "type": "Note",
    "attributedTo": "https://misskey.example/users/a1",
    "to": ["https://other.example/users/b2"],
    "inReplyTo": "https://other.example/notes/9",
    "name": "Option 2"
  }
}
```

The poll itself is the `Question` form of `#Note` in [objects](objects.md).

## Not researched

How `updateQuestion` merges the counts of an incoming `Update`.
