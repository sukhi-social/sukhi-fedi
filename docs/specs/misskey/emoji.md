<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Custom emoji

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `EmojiTag`, defined below

## In one paragraph

A custom emoji travels as a `tag` item of type `Emoji` next to the text that uses `:shortcode:`. The receiver saves the image under that shortcode and draws it in place of the text. Misskey and sukhi both use the Mastodon shape.

## What Misskey does

### Receiving **[src]** `core/activitypub/models/ApNoteService.ts`, `extractEmojis`

- It takes the `tag` items of type `Emoji`.
- It strips the colons from `name` and converts the host to punycode.
- An existing row is updated when it has no `updatedAt`, has no URI while the tag has one, the tag's `updated` is newer, or the icon URL differs. Otherwise a row is inserted.
- A failure is logged and ignored. The note is saved with an empty emoji list.

### Sending **[src]** `ApRendererService.ts`

- A note's `tag` includes `Emoji` items from `renderEmoji`. Emoji marked local-only are skipped.
- The exact fields of an `Emoji` item (`id`, `name`, `updated`, `icon`) were **[not seen]**.
- In the text, `:name:` is wrapped in zero-width spaces in the `content` HTML (see [mfm](mfm.md)).
- A reaction that starts with `:` gets one `Emoji` tag, only if the emoji is in the local cache and not local-only (see [reactions](reactions.md)).

## What sukhi does **[sukhi]**

- Actors and notes carry `Emoji` tags built from the saved emoji; rows without a URL are dropped (`shared/.../actor_json.ex`, `fedi/builders.ex`).
- A reaction adds one `Emoji` tag with the icon URL.
- sukhi's context defines `Emoji` as `toot:Emoji`, as Misskey's does.
- The web client replaces `:code:` by the image with `renderEmojis`, using the `emojis` of the status.

An `Emoji` tag as sukhi sends it (type `EmojiTag`):
```json
{
  "id": "https://sukhi.social/emojis/blobcat.png",
  "type": "Emoji",
  "name": ":blobcat:",
  "icon": {
    "type": "Image",
    "url": "https://sukhi.social/emojis/blobcat.png"
  }
}
```

The type, written as JSDoc so the page can be read on its own (the checker compiles it):

```js
/**
 * A custom emoji item in `tag`, in the shape sukhi sends.
 * @typedef {object} EmojiTag
 * @property {string} [id]
 * @property {'Emoji'} type
 * @property {`:${string}:`} name  The shortcode with its colons.
 * @property {{type: 'Image', url: string}} icon  `url` is an absolute URL.
 */
```

## Not researched

Misskey's handling of an emoji tag with a missing `icon`; emoji in profile names as Misskey shows them.
