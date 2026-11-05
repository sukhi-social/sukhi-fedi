<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Quiet auto-translation — design note

> **Status: built** (PR #150), **off for everyone until they turn it on.** The mock is
> `web-next/ui-lab/mocks/translate-auto` (`make ui-lab`). Choices that were open when this was
> a proposal were settled the recommended way (see the end); change them here if ひなた decides otherwise.
>
> **Intent:** for someone who chose it, a post in a language they cannot read gets a pale
> translation under it by the time they have read the original — without a press, without a
> spinner, and without it ever pretending to be the author's voice.
> **Reader's problem (hypothesis; nobody has told us yet):** "Pressing 訳を見る on every
> post in a language I don't read is a small chore, and on a busy morning I stop pressing and stop
> understanding the people I follow." If the real problem is only a few people in one language,
> the `読めることば` setting plus the button already solves it, and this note should be dropped.

It extends [`TRANSLATION.md`](TRANSLATION.md); it does not change its stance. Translation is a hand that
helps you *hear* — a help for listening, not a replacement for reading — and it is still never
done to you without you having asked. The difference is *when* you ask: once, in settings, for
a whole stretch of reading, instead of once per post.

## What the person sees

- **Off by default.** One switch in `/settings/translation`: 画面に入った投稿を、自動で訳す.
  Turning it on shows, there and only there, two short lines — the text goes to the translator
  when a post stays on screen; and, **only for the engine you chose**, with DeepL "your key, a
  company outside, this month's allowance" / with the server's own translator "stays on this
  server". Everything else (which posts are skipped, that failures stay silent) is folded under
  くわしく. A note read before a switch must be short enough to be read: the facts that change
  the decision first, the rest one tap away.
- **Which posts.** A post is translated on its own only if all of these hold, otherwise it keeps
  the plain 訳を見る button (so the button is always the fallback, never a dead end):
  1. it is in a language that is neither in `読めることば` nor in `学んでいることば`;
  2. the language is *decided* — declared by the post, or an unambiguous script (kana, hangul,
     Cyrillic, …). Han-only text, where `guessLang` says `null`, is not sent: it is often short
     Japanese, and a wasted DeepL call is worse than a button;
  3. it has no content warning. A folded body has not been shown; sending it would translate
     something the author asked you to open on purpose;
  4. it is not a direct message (never translated at all — unchanged), and it is not your own post.
- **Learning stays learning.** A language marked as learning never auto-translates. The point of
  that setting is *you read first*; the button, the closed box and the pale style are as they are.
- **When.** Only while the post is at least 60 % on screen, the tab is visible, and it has
  stayed for about 700 ms. Scrolling past does nothing. There is no look-ahead (unlike
  `a.load-more`): fetching what you may never see is exactly the waste this feature must not
  have, and with DeepL it costs real quota. `Save-Data` turns auto off for that device.
- **How it looks.** Under the original, in the same box as today's translation but pale and small
  (the existing "learning" treatment, opened). The header always says what it is and who made
  it: `訳(機械翻訳・自動) ・ LibreTranslate ・ とじる`. If the post was followers-only and you chose
  DeepL, it says `LibreTranslate`, as now. とじる folds it back to the 訳を見る button and it
  does not come back by itself. It fades in over 240 ms (no motion at all under
  `prefers-reduced-motion`).
- **No jumping.** The translation is added *below* the original. Only posts whose box is already
  at least partly inside the screen are translated, so nothing above the viewport grows and
  pushes you down (browsers without scroll anchoring, Safari, would otherwise jump).
- **Quiet when it can't.** Busy, unavailable, too long, unsupported: nothing is said; the button
  stays. The page backs off automatically (60 s after `busy`, or the `retry-after`) — a press
  of the button still works at any time and says why if it can't.
  The only things said aloud are things you can act on, **once per page**: the DeepL key is
  missing or refused, or this month's allowance is spent. One note, with a way to settings, and
  auto rests until the page is reloaded (`ui-lab`: scene `quota`).
- **If the engine says it is already your language.** `detected_source_language` is in
  `読めることば` (or equals the target): nothing is shown and the button goes away. It is a
  guess corrected after the fact; the text did cross to the engine, which is why the guess above
  is conservative.

## Rules (where each is kept — CODE_STYLE §0)

| Rule | Where | Why there |
| --- | --- | --- |
| The account has turned auto on | **gateway, `SukhiFedi.Translate.status/4`** — an `auto: true` request from an account whose `translate_auto` is not `true` is refused (`:auto_off`) | The web client's idea of the setting is a guess. Whatever a client does, nothing is sent without consent. One check, at the boundary. |
| Visibility, DM, followers-only → hosted, length, key, sanitising | unchanged, the same `Translate.status` path | Auto is the same request with a flag; it cannot bypass what the press cannot. |
| Auto never takes the last place on the server's translator | **`Translate.Gate`**: an auto request runs only while `flight < max_flight`, so a human pressing the button always has one place | With `TRANSLATE_MAX_FLIGHT=2`, auto may use one. |
| Auto has its own hourly allowance, apart from the 60 for presses | `Translate.Gate` (`@auto_per_hour`, provisional — start at 120) | Reading a feed would otherwise spend the hand-pressed allowance in minutes. Over the allowance → `:busy`, which the page treats as quiet. |
| A post is translated once for everyone who needs it | `HotCache` `{:translate, scope, digest, target}`, as now | The cache already keys on text + target + engine (+ account for DeepL). Auto raises the hit rate; nothing new to write. |
| Words shown to the reader: *auto*, engine name | `views/translate.ts` + `locales/translate.ts` | One label function; no second copy for auto. |
| "Should the page try auto for this post" | `web-next/server/translate.ts` `offerFor` → a new `'auto'` offer next to `'ask'` / `'learn'` | A guess only (like today's button). The gateway still decides. |

Not stored, not federated, not shown to anyone else — as before. A 10-minute cache is the only
memory, so reloading after 10 minutes translates again; with DeepL that is the reader's own
quota. See open question 3.

## How it is built (small, reuses the press)

1. **Account field** `translate_auto` (boolean, default false) beside `translate_reads` /
   `translate_learns`: Postgres migration `20261105000002`, `priv/datalevin/catalog.exs`,
   `Account.changeset_credentials`, `update_credentials`, `source.translate_auto` in the account view.
2. **Gateway**: `Translate.status/4` takes `auto: true`; the consent check is first, then
   the content-warning check, then the existing `with` chain; `Gate.run/4` takes `auto: true`
   (own 120/h bucket; at most `max_flight - 1` places on the hosted translator). New reason
   `:auto_off` → `403 auto_off`. Tests: `gate_test` (allowance, last-place rule),
   `integration/translate_test` (refused when off, before the post is read; works when on;
   content warning), `mastodon_translation_test` (`auto` only for the literal `true`).
3. **web-next**
   - `offerFor` returns `'auto'` (a guess) for posts that pass rules 1–4 when `prefs.auto` is on;
     `translateSlot` puts `data-tr-auto` and an empty `auto` field on the slot's form.
   - `public/js/app.js`, `form[data-tr-auto]`: an `IntersectionObserver` (60 % of the post, or
     60 % of the screen for a tall one; 700 ms dwell; visible tab; no `Save-Data`) and **one shared
     queue, one at a time**, 400 ms apart. It sets `auto=1` and submits the slot's own form through
     Unpoly, so the reply is the same fragment a press gets.
   - `routes/translate.ts`: with `auto=1`, quiet problems return the plain button (marked
     `data-tr-quiet=<code>`); `no_key` / `key_rejected` / `quota` return the one note
     (`data-tr-rest`). A result whose detected language is one you read returns nothing.
   - The page backs off 60 s after `busy` / `engine_unavailable` / `failed`, and rests until reload
     after `data-tr-rest`, `disabled` or `auto_off`.
   - Settings: the switch and its short note in `/settings/translation`; the note names only the
     engine you chose.
   - A server-rendered page with JS off never auto-translates; the button is there.
4. **Docs and words**: ja / ko / en strings, `TRANSLATION.md`, `MASTODON_API.md`.

Not needed: a batch endpoint. The gateway, the cache and the engine adapters already serve one
post at a time, and the one-at-a-time queue is what keeps a small box unhurried. A batch would
save HTTP round trips but hold a translator worker longer, which is the scarce thing.

## What this deliberately does not do

- It does not translate on the server for everyone, nor in the background while you are away.
- It does not translate posts you did not see, your own posts, or direct messages.
- It does not rank, hide or reorder posts by language; it does not show a language badge more
  loudly than today.
- It does not auto-switch engines, retry on its own beyond the page's back-off, or show a count
  of what it translated.
- No per-author "do not translate me" flag (still decided against; see `TRANSLATION.md`).

## Settled the recommended way, and what is still a guess

1. **One switch, not per language.** A per-language list (`translate_auto_langs`) can come when someone asks.
2. **Followers-only goes to the server's own translator in auto too**, exactly as a press does, and
   the label names the engine. (Alternative, safer and less useful: followers-only never auto.)
3. **Cache time stays 10 minutes**, the press's number. Raising it for the hosted scope only would
   cost memory, not privacy; measure first.
4. **120 an hour and "leave one place" are guesses**, like the 60 an hour and `TRANSLATE_MAX_FLIGHT=2`
   beside them. They need the same real-box load test before anyone relies on them.
5. **No DeepL usage meter.** The note says it spends your month's allowance; a "about N characters
   this month" would need DeepL's usage endpoint. Worth it if people burn the free tier.
6. **Not verified in a real browser on Safari/iOS** (the no-jump rule relies on translating only
   what is already on screen); Chromium was checked.
