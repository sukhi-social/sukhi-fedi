<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Checking the JSON in the specifications

The shape of each JSON message is written as a [CUE](https://cuelang.org) type inside the page that talks about it, and the example messages on that page are checked against the type. Run it with `make check-specs`. It needs `cue` on the path; `mise.toml` pins it.

## How a page is written

1. A type is a `cue` code block of definitions, for example:

   ````
   ```cue
   #EmojiTag: {
   	type: "Emoji"
   	name: string
   	icon: {url: #URL, ...}
   	...
   }
   ```
   ````

   Each block is its own file of one CUE package (`specs`), so a block may `import` what it needs and may use a definition from any other page. Names must be unique. `#URL` is defined in [misskey/README.md](../misskey/README.md).
2. An example is a `json` block directly after a line that ends with ``(type `#EmojiTag`):``. The checker runs `cue vet -c -d '#EmojiTag'` on it.
3. [`negative.json`](negative.json) lists messages that a type must refuse; the check fails if one is accepted.

## What it cannot say

CUE cannot say "some entry of this array has this value" (a WebFinger answer has a `self` link; a quote's `tag` has a `Link`). Such a rule is a comment next to the property, and is not checked.

A field whose name starts with `_` must be quoted (`"_misskey_content"`), or CUE treats it as hidden and does not match the JSON.
