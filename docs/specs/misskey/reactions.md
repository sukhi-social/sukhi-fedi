<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Reactions

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Schema: [misskey-reaction](../schemas/misskey-reaction.schema.json)

- Misskey sends a reaction as `Like` with `content` and `_misskey_reaction` both set to the reaction string. **[src]** `renderLike`
- A custom emoji gets one `Emoji` tag, only when the reaction starts with `:`, the emoji is in the local cache, and it is not local-only. **[src]** same function
- Misskey reads a reaction from `_misskey_reaction`, then `content`, then `name`. A second reaction by the same user on the same note is skipped (`already reacted`). **[src]** `ApInboxService.ts`
- `EmojiReact` and `EmojiReaction` are accepted as `Like`. The type guard is `['Like', 'EmojiReaction', 'EmojiReact'].includes(type)`, so all three go the same way. **[src]** `core/activitypub/type.ts`, `isLike`. There is no separate handler.
- `Undo` of a `Like` is handled, so a reaction can be removed. **[src]** `ApInboxService.ts`
- Misskey itself sends `Like`. A server that sends `EmojiReact` to Misskey is understood, but a reaction from Misskey to that server comes as `Like`.
- sukhi sends `Like` with `content` and, for custom emoji, an `Emoji` tag. It does not set `_misskey_reaction`, which Misskey does not need because it falls back to `content`. **[sukhi]** `fedi/builders.ex:206-227`
- Because Misskey also accepts `EmojiReact`, the choice to send `Like` is made for other servers (Mastodon reads it as a plain like; Pleroma quarantines `EmojiReact`), not for Misskey. **[sukhi]** `FEDERATION.md` §10
