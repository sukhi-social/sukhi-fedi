<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: JSON-LD context

- Part of [the Misskey specification](README.md); source tags and terms are explained there.

## In one paragraph

Every object Misskey sends starts with an `@context`: the two standard contexts plus one inline term map. The term map is what makes `_misskey_content`, `isCat`, and the rest mean something. It is written out in full as `#Context` in [objects](objects.md).

**[src]** `core/activitypub/misc/contexts.ts`

## What to take from it

- The standard contexts are `https://www.w3.org/ns/activitystreams` and `https://w3id.org/security/v1`.
- Misskey-only terms live in the `misskey:` namespace, `https://misskey-hub.net/ns#`. The exception is `quoteUrl`, which is `as:quoteUrl`.
- Mastodon's terms (`toot:`) cover `Emoji`, `featured`, and `discoverable`.
- `freeText` is typed `schema:text`.

## Things to watch

A term that is not in the `@context` is dropped when the document is expanded as JSON-LD. A Linked-Data signature is made over the expanded document, so a term missing from the context is not covered by it. See also [extensions](extensions.md).
