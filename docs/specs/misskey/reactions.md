<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Reactions

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Type: `#Like`, defined in [activities](activities.md)

## In one paragraph

A reaction is a `Like` that carries an emoji in `content`. Misskey sends it that way, and accepts the types `EmojiReaction` and `EmojiReact` as the same thing.

## What Misskey does

- It sends `Like` with `content` and `_misskey_reaction` both set to the reaction string. **[src]** `renderLike`
- A custom emoji gets one `Emoji` tag, only when the reaction starts with `:`, the emoji is in the local cache, and it is not local-only. **[src]** same function
- It reads the reaction from `_misskey_reaction`, then `content`, then `name`. A second reaction by the same user on the same note is skipped (`already reacted`). **[src]** `ApInboxService.ts`
- `Like`, `EmojiReaction`, and `EmojiReact` all go the same way. The type guard is `['Like', 'EmojiReaction', 'EmojiReact'].includes(type)`, and there is no separate handler. **[src]** `core/activitypub/type.ts`, `isLike`
- `Undo` of a `Like` is handled, so a reaction can be taken back. **[src]** `ApInboxService.ts`

## The reaction string

**[src]** `core/ReactionService.ts`

- A Unicode emoji is stored without variation selectors (U+FE0F), unless it is a ligature joined with U+200D. A few old names (`like`, `love`, `laugh`, ...) become emoji. Anything else that is not an emoji becomes the fallback heart, U+2764.
- A custom emoji is `:name:` with `name` made of letters, digits, `_`, `+`, and `-`. Misskey looks the name up on the reacting server. If it is not known, or not allowed as a reaction, or the note's author has restricted reactions, the reaction becomes the heart.
- Misskey stores a reaction by a local user as `:name:` and one by a remote user as `:name@host:`.
- A `Like` with no reaction string at all is the heart.
- One user has one reaction per note. A different one replaces the old; the same one again is skipped (`already reacted`).
- A reaction to a plain renote is refused; to a quote, it is allowed.

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
