<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Translating posts

> **Intent:** a post is first a person's voice. Translation is a hand that helps you
> hear it — it never lies over it, and it is never done to you without you asking.
> **Reader's problem (hypothesis):** "someone I follow writes in a language I can't
> quite read. I want to understand them (or practise their language) without handing
> my reading over to a machine, and without my posts or key going somewhere I did not choose."

## What the person sees

- A post in a language you did not mark as readable shows one small button, **訳を見る**.
  Nothing is translated until you press it. There is no "translate everything".
- The original is never moved. The translation is added **directly beneath it**, in a box
  whose header always names the engine (`訳(機械翻訳) · DeepL`) and offers とじる.
- If you marked a language as one you are **learning**, the button reads **訳をひらく**,
  the box starts closed, and the translation is lighter and smaller than the original even
  when open. That is the whole of "learning" — no word lists, no cloze, no scoring.
- Settings (読めることば / 学んでいることば / 訳し役 / DeepL key) live in one place. The
  note "your post text goes to a company outside this server" is shown **once, there**, when
  you choose DeepL — not on the timeline.

## Rules (all enforced in `SukhiFedi.Translate`, nowhere else)

| Rule | Why |
| --- | --- |
| Direct messages are never translated | Nothing about a DM leaves the conversation. |
| Followers-only posts go only to the server's own translator, even if you chose DeepL | The author chose a small audience; a third party is outside it. The box says which engine was used. |
| Only public / unlisted posts can go to DeepL, with the reader's own key | Bring-your-own-key: the cost and the relationship with DeepL are the reader's. |
| The engine never changes silently | If the chosen engine is unavailable you are told; you are not moved to another. |
| Translations are never stored, federated or shown to anyone else | Only a 10-minute cache of *successful* results, keyed by text + target (+ account for DeepL). |
| Text over 3000 characters is refused (`too_long`) | A half translation is a worse lie than none. |
| 60 requests / hour / account; at most `TRANSLATE_MAX_FLIGHT` (default 2) in flight against the hosted translator | Keeps a small box unhurried. A full queue answers `429` with `retry-after`; nothing retries by itself. |

The DeepL key is write-only: sealed with AES-GCM (key derived from `SECRET_KEY_BASE`,
bound to the account id), never returned by any API (only the last four characters),
blanked at the RPC gate, and removable at any time. Rotating `SECRET_KEY_BASE` makes stored
keys unreadable; people simply enter them again.

## Where the code is

```
web-next  →  POST /api/v1/statuses/:id/translate  (api, scope read:statuses)
          →  GatewayRpc  →  SukhiFedi.Translate  →  Translate.Gate  →  LibreTranslate | DeepL
```

- web-next: `server/translate.ts` (whether to offer the button — a guess, never a guard),
  `server/routes/translate.ts` (the press, and `/settings/translation`),
  `server/views/translate.ts` (the box, the notes), `server/locales/translate.ts` (words).
  The open translation is `up-keep`, so favouriting a post does not close it.
- `SukhiFedi.Translate` — visibility, engine choice, text extraction, sanitising the result.
- `Translate.Gate` — per-account hourly bucket and the in-flight cap.
- `Translate.LibreTranslate`, `Translate.DeepL` — adapters. Fixed egress hosts; no redirects;
  no retries; 20 s timeout. They trust the caller.
- `Translate.Key` — sealing / opening the DeepL key.
- API surface and errors: [`MASTODON_API.md`](MASTODON_API.md#translation).

## Running LibreTranslate

Run it as its **own container on the private network** (never published), loading only the
languages sukhi offers (ja, en, ko) so memory stays small:

```
LT_LOAD_ONLY=ja,en,ko
```

Point the gateway at it with `LIBRETRANSLATE_URL` (see [`ENV.md`](ENV.md)). Without that
variable, the hosted choice reports `disabled` and the button is not offered unless the
reader has a DeepL key.

The in-flight default of 2 is **provisional**. Before raising it, load-test on the real box:
translate a long post repeatedly while watching memory and the delivery queue.

## Not done yet

- The post's *declared* language (`language` in status JSON is empty today). web-next guesses
  from the script (kana → ja, hangul → ko, …) only to decide whether to show the button;
  Han-only or Latin text shows it and lets the engine detect.
- Further target languages beyond ja / ko / en — follows the English-support work.
- Ingest still picks the first `contentMap` key as the language, which can disagree with `content`;
  fixing that (and storing the declared language) is the next small step.
- No "please don't translate me" flag for authors (decided against, for now).
