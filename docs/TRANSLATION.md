<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Translating posts

> **Intent:** a post is first a person's voice. Translation is a hand that helps you
> hear it — it never lies over it, and it is never done to you without you asking.
> **Reader's problem (hypothesis):** "someone I follow writes in a language I can't
> quite read. I want to understand them (or practise their language) without handing
> my reading over to a machine, and without my posts or key going somewhere I did not choose."

## What the person sees

- A post in a language you did not mark as readable shows one small button, **訳を見る**.
  Nothing is translated until you press it — unless you turn on auto-translation (below). There is no "translate everything".
- The original is never moved. The translation is added **directly beneath it**, in a box
  whose header always names the engine (`訳(機械翻訳) · DeepL`) and offers とじる.
- If you marked a language as one you are **learning**, the button reads **訳をひらく**,
  the box starts closed, and the translation is lighter and smaller than the original even
  when open. That is the whole of "learning" — no word lists, no cloze, no scoring.
- **Only if you turn it on** (off by default), posts that stay on screen are translated for you
  and shown the same way, paler, with `訳(機械翻訳・自動)` and the engine name. Failures stay
  silent; the button is still there. The whole of it, and why it is shaped this way:
  [`TRANSLATION_AUTO.md`](TRANSLATION_AUTO.md).
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
| An automatic request is refused unless the account turned `translate_auto` on; it is never sent for a post behind a content warning | A page asking by itself is held to what the person agreed to. Checked in `SukhiFedi.Translate`, before anything about the post is read. |
| Automatic requests: 120 / hour / account, apart from the 60 for presses; they never take the hosted translator's last free place | `Translate.Gate`. Reading a feed must not spend what a person asked for by hand. |
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

It is **opt-in**. The release and every `main` sha (`combined-sha`) build an image,
`sukhi-fedi-translate`, from [`translate/Dockerfile`](../translate/Dockerfile): upstream LibreTranslate (pinned) with only
ja, en and ko baked in, so it starts quickly and never fetches models at run time. The
compose file has it behind a profile:

```
# .env
LIBRETRANSLATE_URL=http://translate:5000

docker compose --profile translate up -d
```

- It is **not published**; only the gateway talks to it, on the compose network.
- Two workers (`LT_THREADS=2`), matching `TRANSLATE_MAX_FLIGHT`. No web page, no key database.
- Expect on the order of 1–2 GB of RAM — a rough guess, **not measured**. Check on the real box
  before you rely on it. The small free-tier boxes cannot carry it; there, people can still use
  their own DeepL key.
- Without `LIBRETRANSLATE_URL`, the hosted choice reports `disabled` and the button is offered
  only to people who have a DeepL key.
- Bump the base with `--build-arg LT_VERSION=…` (or the `ARG` in the Dockerfile) on purpose.

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
