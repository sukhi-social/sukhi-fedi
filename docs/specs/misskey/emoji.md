<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Custom emoji

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Schema: `schemas/emoji-tag.schema.json`

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

An `Emoji` tag as sukhi sends it ([emoji-tag schema](../schemas/emoji-tag.schema.json)):
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

The schema, copied here so the page can be read on its own:

<!-- schema: emoji-tag.schema.json -->
```json
{
  "$schema": "http://json-schema.org/draft-04/schema#",
  "id": "https://sukhi.social/spec/schemas/emoji-tag.schema.json",
  "$comment": "SPDX-License-Identifier: AGPL-3.0-or-later",
  "title": "Custom emoji tag",
  "description": "The `tag` item that carries a custom emoji, in the shape sukhi sends (actors, notes, reactions). Misskey's exact fields for the same item were not read; Misskey reads `type` and `name` and the icon URL (see misskey/emoji.md).",
  "type": "object",
  "required": [
    "type",
    "name",
    "icon"
  ],
  "properties": {
    "id": {
      "type": "string",
      "format": "uri"
    },
    "type": {
      "enum": [
        "Emoji"
      ]
    },
    "name": {
      "type": "string",
      "pattern": "^:[^:\\s]+:$",
      "description": "The shortcode with its colons."
    },
    "icon": {
      "type": "object",
      "required": [
        "type",
        "url"
      ],
      "properties": {
        "type": {
          "enum": [
            "Image"
          ]
        },
        "url": {
          "type": "string",
          "format": "uri"
        }
      }
    }
  }
}
```

## Not researched

Misskey's handling of an emoji tag with a missing `icon`; emoji in profile names as Misskey shows them.
