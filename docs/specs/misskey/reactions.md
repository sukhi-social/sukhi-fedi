<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Reactions

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `#Reaction`, defined below

## In one paragraph

A reaction is a `Like` that carries an emoji in `content`. Misskey sends it that way, and accepts the types `EmojiReaction` and `EmojiReact` as the same thing.

## What Misskey does

- It sends `Like` with `content` and `_misskey_reaction` both set to the reaction string. **[src]** `renderLike`
- A custom emoji gets one `Emoji` tag, only when the reaction starts with `:`, the emoji is in the local cache, and it is not local-only. **[src]** same function
- It reads the reaction from `_misskey_reaction`, then `content`, then `name`. A second reaction by the same user on the same note is skipped (`already reacted`). **[src]** `ApInboxService.ts`
- `Like`, `EmojiReaction`, and `EmojiReact` all go the same way. The type guard is `['Like', 'EmojiReaction', 'EmojiReact'].includes(type)`, and there is no separate handler. **[src]** `core/activitypub/type.ts`, `isLike`
- `Undo` of a `Like` is handled, so a reaction can be taken back. **[src]** `ApInboxService.ts`

## Examples

A reaction with a Unicode emoji (type `#Reaction`):
```json
{
  "type": "Like",
  "actor": "https://misskey.example/users/a",
  "object": "https://other.example/notes/1",
  "content": "👍",
  "_misskey_reaction": "👍"
}
```

A reaction with a custom emoji (type `#Reaction`):
```json
{
  "id": "https://misskey.example/likes/1",
  "type": "Like",
  "actor": "https://misskey.example/users/a",
  "object": "https://other.example/notes/1",
  "content": ":blobcat:",
  "_misskey_reaction": ":blobcat:",
  "tag": [
    {
      "type": "Emoji",
      "name": ":blobcat:",
      "icon": {
        "type": "Image",
        "url": "https://misskey.example/files/blobcat.png"
      }
    }
  ]
}
```

The type, in [CUE](https://cuelang.org):

```cue
// A reaction: a Like that carries `content`. Misskey also accepts the types
// `EmojiReaction` and `EmojiReact`, and reads the string from
// `_misskey_reaction`, then `content`, then `name`.
#Reaction: {
	id?:                 #URL
	type:                "Like" | "EmojiReaction" | "EmojiReact"
	actor:               #URL
	object:              #URL
	content:             string & !=""
	"_misskey_reaction"?: content
	tag?:                [] | [#EmojiTag] // at most one emoji
	...
}
```

The type refers to `#EmojiTag`, which is on the [emoji](emoji.md) page.
