<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# JSON Schemas

Shapes of the JSON that the specifications talk about, written as JSON Schema (draft 4). Each schema has an `id` under `https://sukhi.social/spec/schemas/`. The documents that use a schema print it in full, and show example messages directly under a link to it.

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

## Checking

`make check-specs` runs [`check/check.cjs`](../check/check.cjs). It does three things:

1. Every JSON example in a document that sits directly under a link to a `.schema.json` file is validated against that schema, with [skeemas-markdown-validation](https://github.com/skeemas/skeemas-markdown-validation).
2. Every schema printed in a document (after `<!-- schema: NAME -->`) is identical to the file in this folder.
3. The messages in [`check/negative.json`](../check/negative.json) are rejected by the schema they name.

Why draft 4: skeemas validates draft 3 and 4 only, and it is not maintained. Draft 4 has no `contains`, so one rule (a quote has a `tag` `Link`) is stated in the schema's `description` and not checked. If this becomes a problem, the same check can be done with Ajv, which supports 2020-12.

Not covered: a schema for whole Notes or actors. Their shapes are large and open (any extension may appear), so these schemas fix only the properties a specification is about.
