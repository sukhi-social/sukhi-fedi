<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Custom emoji

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `#EmojiTag`, defined below

## In one paragraph

A custom emoji travels as a `tag` item of type `Emoji` next to the text that uses `:shortcode:`. The receiver saves the image under that shortcode and draws it in place of the text. Misskey uses the Mastodon shape.

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

## An example

An `Emoji` tag (type `#EmojiTag`):
```json
{
  "id": "https://misskey.example/emojis/blobcat",
  "type": "Emoji",
  "name": ":blobcat:",
  "icon": {
    "type": "Image",
    "url": "https://misskey.example/files/blobcat.png"
  }
}
```

The type, in [CUE](https://cuelang.org):

```cue
// An item of `tag` that carries a custom emoji. Misskey reads `type`, `name`,
// and the icon URL; its other fields (`id`, `updated`) were not read, so they
// are optional here. `icon` is required here because a receiver has nothing
// to draw without it; Misskey's handling of a missing icon was not read.
#EmojiTag: {
	id?:      string
	type:     "Emoji"
	name:     string
	updated?: string
	icon: {
		type?: string
		url:   #URL
		...
	}
	...
}
```

## Not researched

Misskey's handling of an emoji tag with a missing `icon`; emoji in profile names as Misskey shows them.
