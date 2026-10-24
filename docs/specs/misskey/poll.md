<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Polls

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `PollVote`, defined below

## In one paragraph

A poll is a `Question`-like note whose choices are listed under `oneOf` or `anyOf`. A vote is a tiny `Note` whose `name` is the chosen option and which replies to the poll. Misskey counts such a note as a vote and does not create a note. sukhi sends votes in the same shape.

## What Misskey does

- A poll in a note is written under `oneOf` (one answer) or `anyOf` (several). Each choice is a `Note` with `name` and `replies`. The end is `endTime`, or `closed` when over. **[src]** `renderNote`
- A vote is a `Note` whose `name` matches a choice and whose `inReplyTo` is the poll. It is counted and no note is created. A vote on an expired poll is skipped. **[src]** `ApNoteService.ts`
- New counts travel as an `Update` of a `Question`, with `_misskey_votes` on each choice. **[src]** `renderQuestion`, `ApInboxService.ts`

## What sukhi does **[sukhi]** `fedi/builders.ex` (`vote/1`)

A vote is a `Create` of a `Note` that has `name`, `inReplyTo`, and `to` set to the poll's author. It has no `content` and no `cc`.

A vote as sukhi sends it (type `PollVote`):
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

The type, written as JSDoc so the page can be read on its own (the checker compiles it):

```js
/**
 * A vote: a Create of a small Note whose `name` is the chosen option and whose
 * `inReplyTo` is the poll. Misskey counts it and creates no note.
 * @typedef {object} PollVote
 * @property {'Create'} type
 * @property {string} actor
 * @property {[string, ...string[]]} [to]
 * @property {PollVoteNote} object
 *
 * @typedef {object} PollVoteNote
 * @property {'Note'} type
 * @property {string} attributedTo
 * @property {string} name  The chosen option. Not empty.
 * @property {string} inReplyTo  URL of the poll.
 * @property {[string, ...string[]]} [to]  The poll's author.
 * @property {never} [content]  A vote carries no text.
 * @property {never} [cc]
 */
```

## Not researched

Whether sukhi reads `_misskey_votes`; how sukhi shows updated counts from Misskey.
