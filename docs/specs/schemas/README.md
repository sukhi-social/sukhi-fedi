<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# JSON Schemas

Shapes of the JSON that the specifications talk about, written as JSON Schema (draft 2020-12). Each schema has an `$id` under `https://sukhi.social/spec/schemas/`, and carries `examples`.

A schema either **binds** (it states what a sukhi message looks like under a numbered specification) or **describes** (it states what Misskey sends or reads, with no duty on anyone). The `description` of each schema says which.

| Schema | Kind | Used by |
| --- | --- | --- |
| [quote-note](quote-note.schema.json) | binds | [sukhi-0003](../sukhi-0003-legacy-quote-profile.md) |
| [emoji-tag](emoji-tag.schema.json) | binds (sukhi's shape) | [misskey/emoji.md](../misskey/emoji.md) |
| [misskey-mfm-source](misskey-mfm-source.schema.json) | describes | [misskey/mfm.md](../misskey/mfm.md) |
| [misskey-reaction](misskey-reaction.schema.json) | describes | [misskey/reactions.md](../misskey/reactions.md) |
| [poll-vote](poll-vote.schema.json) | describes; sukhi sends it | [misskey/poll.md](../misskey/poll.md) |
| [webfinger-jrd](webfinger-jrd.schema.json) | describes; sukhi sends it | [misskey/webfinger.md](../misskey/webfinger.md) |
| [nodeinfo-metadata](nodeinfo-metadata.schema.json) | describes | [misskey/nodeinfo.md](../misskey/nodeinfo.md) |

Checked on 2026-10-24: every schema is valid draft 2020-12, every example passes its schema, and four deliberately wrong messages (a quote with one form only, MFM `_misskey_content` without `source`, a `source` with another media type, a vote carrying `content`) are rejected. The check was run once by hand and is not part of `make test`.

Not covered: a schema for whole Notes or actors. Their shapes are large and open (any extension may appear), so these schemas fix only the properties a specification is about.
