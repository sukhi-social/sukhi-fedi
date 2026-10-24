<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Checking the JSON in the specifications

The specifications describe JSON messages. The shape of each message is written as a JSDoc type inside the page that talks about it, and the example messages on that page are checked against the type. Run it with `make check-specs`.

## How a page is written

1. A type is a `js` code block of `@typedef`s:

   ````
   ```js
   /**
    * @typedef {object} EmojiTag
    * @property {'Emoji'} type
    * @property {`:${string}:`} name  The shortcode with its colons.
    */
   ```
   ````

2. An example is a `json` block directly after a line that ends with ``(type `EmojiTag`):``.
3. `negative.js` lists messages the types must refuse. Each one has a `// @ts-expect-error` line, and the check fails if the compiler accepts it.

All blocks of all pages are put in one file, so a type may use a type from another page (`Reaction` uses `EmojiTag`). Names must be unique.

## What it cannot say

The check is the TypeScript compiler (`strict`, `checkJs`). It does not check that a string is a URL, and it cannot say "some entry of this array is a `Link`" (a quote's `tag`). Such rules are written in the comment next to the property.
