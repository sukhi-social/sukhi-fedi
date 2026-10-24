<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Custom emoji

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Type: `#Emoji`, defined in [objects](objects.md)

## In one paragraph

A custom emoji travels as a `tag` item of type `Emoji` next to the text that uses `:shortcode:`. The receiver saves the image under that shortcode and draws it in place of the text. Misskey uses the Mastodon shape.

## What Misskey does

### Receiving **[src]** `core/activitypub/models/ApNoteService.ts`, `extractEmojis`

- It takes the `tag` items of type `Emoji`.
- It strips the colons from `name` and converts the host to punycode. The shortcode is made of letters, digits, `_`, `+`, and `-` (the reaction rule in [reactions](reactions.md)).
- An existing row is updated when it has no `updatedAt`, has no URI while the tag has one, the tag's `updated` is newer, or the icon URL differs. Otherwise a row is inserted.
- A failure is logged and ignored. The note is saved with an empty emoji list.

### Sending **[src]** `ApRendererService.ts`

- A note's `tag` includes `Emoji` items from `renderEmoji`. Emoji marked local-only are skipped.
- The fields of an `Emoji` item are in `renderEmoji`; see the type.
- In the text, `:name:` is wrapped in zero-width spaces in the `content` HTML (see [mfm](mfm.md)).
- A reaction that starts with `:` gets one `Emoji` tag, only if the emoji is in the local cache and not local-only (see [reactions](reactions.md)).

## An example

An `Emoji` tag (type `#Emoji`):
```json
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
```

## Not researched

Misskey's handling of an emoji tag with a missing `icon`; emoji in profile names as Misskey shows them.
