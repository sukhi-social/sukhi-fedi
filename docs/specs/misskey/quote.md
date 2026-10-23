<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Quotes

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

- Misskey resolves a quote only from `_misskey_quote` or `quoteUrl`. **[src]** `ApNoteService.ts`
- It reads neither `quoteUri` nor a tag `Link` with a `rel`. **[src]** same file, **[not seen]** elsewhere. A FEP-e232 tag on its own is therefore not shown as a quote by Misskey.
- Candidates are resolved in parallel. If none resolves and any failure was temporary, creation fails with `quote resolve failed`. A permanent failure means the note is saved without the quote.
- sukhi sends `quoteUrl`, `_misskey_quote`, and the tag `Link`, so Misskey sees the first two. **[sukhi]** `fedi/builders.ex:347-364`. See [sukhi-0003](../sukhi-0003-legacy-quote-profile.md).
