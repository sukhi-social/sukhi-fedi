<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Native seams — where a NIF would plug in

Four pure computations are separated from their callers so a native
(Rust/NIF) implementation can be added later **without touching a caller**.
Nothing here is native yet: each seam has exactly one implementation, the
Elixir one that was already there, moved verbatim. Behaviour did not
change (see "How equivalence was checked").

| seam (`SukhiFedi.Backend`) | facade                              | behaviour                              | Elixir implementation                        |
|----------------------------|-------------------------------------|----------------------------------------|----------------------------------------------|
| `:html_sanitizer`          | `SukhiFedi.HTML.sanitize/1`         | `SukhiFedi.HTML.Sanitizer`             | `HTML.Sanitizer.Elixir` (HtmlSanitizeEx)     |
| `:linkify_scanner`         | `SukhiFedi.Linkify.run/2`           | `SukhiFedi.Linkify.Scanner`            | `Linkify.Scanner.Elixir`                     |
| `:preview_meta`            | `SukhiFedi.PreviewCards.parse_og/2` | `SukhiFedi.PreviewCards.Meta`          | `PreviewCards.Meta.Elixir`                   |
| `:markdown`                | `SukhiFedi.Markdown.to_html/2`      | `SukhiFedi.Markdown.Renderer`          | `Markdown.Renderer.Elixir` (Earmark)         |

The allow-list the sanitizer enforces is data, not code:
`SukhiFedi.HTML.Policy.tags/0`. A native sanitizer is handed that table, so
the policy still lives in one place.

## The pattern

```
caller -> facade -> Backend.call(seam, fun, args) -> impl(seam) (primary)
                                  \-> shadow impls: compared, logged, never returned
```

* `config :sukhi_fedi, :backends, html_sanitizer: MyNative` picks the primary.
* `config :sukhi_fedi, :shadow_backends, html_sanitizer: [MyNative]` runs
  extra implementations on the same input and logs a **disagreement**
  (sizes and an args hash only — never content). The primary's answer is
  what is returned; a shadow that raises is swallowed.
* Both default to "Elixir only"; with no config nothing extra runs.

## Adding a native backend

1. Implement the seam's behaviour (`@behaviour SukhiFedi.HTML.Sanitizer`, …).
2. Add the module to `Backend.implementations/1` for that seam. The
   **contract tests** (`test/sukhi_fedi/backend/contract_test.exs`) run over
   that list, so the new module is held to the same claims as the Elixir one.
3. Turn it on as a **shadow** first, read the disagreement log, fix.
4. Flip it to primary. Keep the Elixir one as the shadow for a while.

## What a NIF must decide

* **Invalid UTF-8.** The Elixir implementations *raise* on it (HtmlSanitizeEx,
  the scanner); the contracts only promise valid UTF-8. A Rust `&str` API
  would reject it too — decide whether to raise, or to scrub first at the
  boundary (once, in the facade, not in every implementation).
* **Dirty schedulers.** Sanitizing a 100,000-character note (the content cap)
  can exceed the ~1 ms NIF budget; use a dirty CPU scheduler.
* **Size bounds.** Bound inputs where they enter (note content cap; request
  bodies are capped by `Plug.Parsers`, 8 MB by default), not inside the NIF.
* **Policy at init.** Pass `Policy.tags/0` once, not per call.
* **Markdown output is not safe.** `Renderer.render/1` passes raw HTML blocks
  through; `Markdown.to_html/2` always sanitizes afterwards. A native
  renderer inherits that: it must not be called without the sanitizer.

## Quirks the contract tests found (inherited, not introduced)

* The sanitizer **settles** but is not idempotent: a second pass can change
  the output (49 of 20,000 random inputs; whitespace-only input becomes `""`).
  The contract says "settles after one more pass".
* Earmark raises (`CaseClauseError`) on some malformed HTML blocks, so
  `Markdown.to_html/2` can raise on such input — as it did before the split.
* OpenGraph parsing compiles its regexes on every call (performance only).

## Why other candidates are not seams

Timeline assembly (SQL and list diffs), streaming fan-out, base58 / Snowflake
/ TOTP, and regex work (BEAM's `:re` is C already) would not get faster in
Rust. LD signatures already go through ojak (`SukhiFedi.Fedi.Ojak`).

## How equivalence was checked

For the sanitizer, scanner and OpenGraph parser the pre-split source was
loaded next to the new one and run on random corpora (20k / 100k / 30k
inputs including garbage and markup soups): zero differences. The markdown
seam is a direct move of the same `Earmark.as_html!/2` call and is covered by
the existing markdown tests plus the contract tests; no differential run.
