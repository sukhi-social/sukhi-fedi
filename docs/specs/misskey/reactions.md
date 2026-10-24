<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Reactions

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Schema: `schemas/misskey-reaction.schema.json`

## In one paragraph

A reaction is a `Like` that carries an emoji in `content`. Misskey sends it that way, and accepts the types `EmojiReaction` and `EmojiReact` as the same thing. sukhi sends a plain `Like` with `content`, which Misskey understands.

## What Misskey does

- It sends `Like` with `content` and `_misskey_reaction` both set to the reaction string. **[src]** `renderLike`
- A custom emoji gets one `Emoji` tag, only when the reaction starts with `:`, the emoji is in the local cache, and it is not local-only. **[src]** same function
- It reads the reaction from `_misskey_reaction`, then `content`, then `name`. A second reaction by the same user on the same note is skipped (`already reacted`). **[src]** `ApInboxService.ts`
- `Like`, `EmojiReaction`, and `EmojiReact` all go the same way. The type guard is `['Like', 'EmojiReaction', 'EmojiReact'].includes(type)`, and there is no separate handler. **[src]** `core/activitypub/type.ts`, `isLike`
- `Undo` of a `Like` is handled, so a reaction can be taken back. **[src]** `ApInboxService.ts`

## What sukhi does **[sukhi]** `fedi/builders.ex:206-227`

sukhi sends `Like` with `content` and, for custom emoji, an `Emoji` tag. It does not set `_misskey_reaction`, which Misskey does not need because it falls back to `content`.

The choice of `Like` is made for other servers, not for Misskey: Mastodon reads it as a plain like, and Pleroma quarantines `EmojiReact` (`FEDERATION.md` §10).

A reaction as sukhi sends it ([misskey-reaction schema](../schemas/misskey-reaction.schema.json)):
```json
{
  "id": "https://sukhi.social/likes/1",
  "type": "Like",
  "actor": "https://sukhi.social/users/hina",
  "object": "https://remote.example/notes/1",
  "content": ":blobcat:",
  "tag": [
    {
      "type": "Emoji",
      "name": ":blobcat:",
      "icon": {
        "type": "Image",
        "url": "https://sukhi.social/emojis/blobcat.png"
      }
    }
  ]
}
```

A reaction as Misskey sends it, with a Unicode emoji ([misskey-reaction schema](../schemas/misskey-reaction.schema.json)):
```json
{
  "type": "Like",
  "actor": "https://remote.example/users/a",
  "object": "https://sukhi.social/users/hina/notes/1",
  "content": "👍",
  "_misskey_reaction": "👍"
}
```

The schema, copied here so the page can be read on its own:

<!-- schema: misskey-reaction.schema.json -->
```json
{
  "$schema": "http://json-schema.org/draft-04/schema#",
  "id": "https://sukhi.social/spec/schemas/misskey-reaction.schema.json",
  "$comment": "SPDX-License-Identifier: AGPL-3.0-or-later",
  "title": "Emoji reaction (Like with content)",
  "description": "Descriptive: a reaction as Misskey sends it, and as sukhi sends it (without `_misskey_reaction`, which Misskey does not need). Misskey also accepts the types `EmojiReaction` and `EmojiReact` (see misskey/reactions.md).",
  "type": "object",
  "required": [
    "type",
    "actor",
    "object",
    "content"
  ],
  "properties": {
    "id": {
      "type": "string",
      "format": "uri"
    },
    "type": {
      "enum": [
        "Like",
        "EmojiReaction",
        "EmojiReact"
      ]
    },
    "actor": {
      "type": "string",
      "format": "uri"
    },
    "object": {
      "type": "string",
      "format": "uri"
    },
    "content": {
      "type": "string",
      "minLength": 1,
      "description": "A Unicode emoji, or a shortcode such as :blobcat:."
    },
    "_misskey_reaction": {
      "type": "string",
      "description": "Misskey sets this to the same string as content."
    },
    "tag": {
      "type": "array",
      "maxItems": 1,
      "items": {
        "$ref": "emoji-tag.schema.json"
      }
    }
  }
}
```

Note that the embedded schema refers to `emoji-tag.schema.json`, which is on the [emoji](emoji.md) page.
