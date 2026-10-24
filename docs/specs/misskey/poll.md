<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Polls

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `#PollVote`, defined below

## In one paragraph

A poll is a `Question`-like note whose choices are listed under `oneOf` or `anyOf`. A vote is a tiny `Note` whose `name` is the chosen option and which replies to the poll. Misskey counts such a note as a vote and does not create a note.

## What Misskey does

- A poll in a note is written under `oneOf` (one answer) or `anyOf` (several). Each choice is a `Note` with `name` and `replies`. The end is `endTime`, or `closed` when over. **[src]** `renderNote`
- A vote is a `Note` whose `name` matches a choice and whose `inReplyTo` is the poll. It is counted and no note is created. A vote on an expired poll is skipped. **[src]** `ApNoteService.ts`
- New counts travel as an `Update` of a `Question`, with `_misskey_votes` on each choice. **[src]** `renderQuestion`, `ApInboxService.ts`

## An example

A vote, as a `Create` (type `#PollVote`):
```json
{
  "type": "Create",
  "actor": "https://other.example/users/b",
  "to": ["https://misskey.example/users/a"],
  "object": {
    "type": "Note",
    "attributedTo": "https://other.example/users/b",
    "name": "Option 2",
    "inReplyTo": "https://misskey.example/notes/9",
    "to": ["https://misskey.example/users/a"]
  }
}
```

The type, in [CUE](https://cuelang.org):

```cue
// A vote: a Create of a small Note whose `name` is the chosen option and
// whose `inReplyTo` is the poll. Misskey counts it and creates no note.
#PollVote: {
	type:  "Create"
	actor: #URL
	to?:   [string, ...string]
	object: {
		type:         "Note"
		attributedTo: #URL
		name:         string & !=""
		inReplyTo:    #URL
		...
	}
	...
}
```

## Not researched

How Misskey writes `replies` and `endTime` in the choices; the exact count of an `Update` of a `Question`.
