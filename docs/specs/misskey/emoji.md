<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: custom emoji

- Kind: descriptive (what Misskey does), with a last section on how sukhi supports it. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Schema: [emoji-tag](../schemas/emoji-tag.schema.json)

## 1. Receiving **[src]** `core/activitypub/models/ApNoteService.ts`, `extractEmojis`

- Takes the `tag` items of type `Emoji`.
- Strips the colons from `name`, and converts the host to punycode.
- An existing row is updated when it has no `updatedAt`, has no URI while the tag has one, the tag's `updated` is newer, or the icon URL differs. Otherwise a new row is inserted.
- A failure is logged and ignored. The note is saved with an empty emoji list.

## 2. Sending **[src]** `ApRendererService.ts`

- A note's `tag` includes `Emoji` items from `renderEmoji`. Emoji marked local-only are skipped.
- The exact fields of an `Emoji` item (`id`, `name`, `updated`, `icon`) were **[not seen]**.
- In text, `:name:` is wrapped in zero-width spaces in the `content` HTML (see [mfm](mfm.md)).

## 3. Reactions

A reaction that starts with `:` gets one `Emoji` tag, only if the emoji is in the local cache and not local-only. See [reactions](reactions.md).

## 4. sukhi **[sukhi]**

- Actors carry `tag` entries `{ "id": <url>, "type": "Emoji", "name": ":code:", "icon": { "type": "Image", "url": <url> } }`; rows without a URL are dropped. (`shared/.../actor_json.ex`)
- Notes carry the same shape. A reaction adds one `Emoji` tag with the icon URL. (`fedi/builders.ex`)
- sukhi's context defines `Emoji` as `toot:Emoji`, as Misskey does.
- The web client replaces `:code:` with the image by `renderEmojis`, using the `emojis` of the status.

## 5. Not researched

- Misskey's handling of an emoji tag with a missing `icon`.
- Emoji in profile names, as shown by Misskey.
