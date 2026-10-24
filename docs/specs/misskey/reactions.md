<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Reactions

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `#Like`, defined in [activities](activities.md)

## In one paragraph

A reaction is a `Like` that carries an emoji in `content`. Misskey sends it that way, and accepts the types `EmojiReaction` and `EmojiReact` as the same thing.

## What Misskey does

- It sends `Like` with `content` and `_misskey_reaction` both set to the reaction string. **[src]** `renderLike`
- A custom emoji gets one `Emoji` tag, only when the reaction starts with `:`, the emoji is in the local cache, and it is not local-only. **[src]** same function
- It reads the reaction from `_misskey_reaction`, then `content`, then `name`. A second reaction by the same user on the same note is skipped (`already reacted`). **[src]** `ApInboxService.ts`
- `Like`, `EmojiReaction`, and `EmojiReact` all go the same way. The type guard is `['Like', 'EmojiReaction', 'EmojiReact'].includes(type)`, and there is no separate handler. **[src]** `core/activitypub/type.ts`, `isLike`
- `Undo` of a `Like` is handled, so a reaction can be taken back. **[src]** `ApInboxService.ts`

## Examples

A reaction with a Unicode emoji (type `#Like`):
```json
{
  "id": "https://misskey.example/likes/r1",
  "type": "Like",
  "actor": "https://misskey.example/users/a1",
  "object": "https://other.example/notes/1",
  "content": "👍",
  "_misskey_reaction": "👍"
}
```

A reaction with a custom emoji (type `#Like`):
```json
{
  "id": "https://misskey.example/likes/r2",
  "type": "Like",
  "actor": "https://misskey.example/users/a1",
  "object": "https://other.example/notes/1",
  "content": ":blobcat:",
  "_misskey_reaction": ":blobcat:",
  "tag": [
    {
      "id": "https://misskey.example/emojis/blobcat",
      "type": "Emoji",
      "name": ":blobcat:",
      "updated": "2026-10-01T00:00:00.000Z",
      "icon": {
        "type": "Image",
        "mediaType": "image/png",
        "url": "https://misskey.example/files/blobcat.png"
      },
      "_misskey_license": {"freeText": null}
    }
  ]
}
```

What Misskey sends is the type above. What it accepts is looser: the types `EmojiReaction` and `EmojiReact` count as `Like`, and the string is read from `_misskey_reaction`, then `content`, then `name`.
