<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Polls

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Schema: [poll-vote](../schemas/poll-vote.schema.json)

- A poll in a note is written under `oneOf` or `anyOf`, chosen by whether multiple answers are allowed. Each choice is a `Note` with `name` and `replies`. The end is `endTime`, or `closed` when over. **[src]** `renderNote`
- A vote is a `Note` whose `name` matches a choice and whose `inReplyTo` is the poll. It is counted as a vote and no note is created. A vote on an expired poll is skipped. **[src]** `ApNoteService.ts`
- Updated counts travel as `Update` of a `Question`, with `_misskey_votes` per choice. **[src]** `renderQuestion`, `ApInboxService.ts`
- sukhi's vote has the same shape: a `Create(Note)` with `name`, `inReplyTo`, and `to` set to the poll author. **[sukhi]** `fedi/builders.ex` (`vote/1`)
