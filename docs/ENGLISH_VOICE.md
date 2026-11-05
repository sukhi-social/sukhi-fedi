<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The English voice

> **Intent:** someone who reads English should land on a sukhi screen and feel the same
> thing a Japanese or Korean reader feels: no hurry, nobody grading you, a place you
> can sit down in. Same promises ([`KINDNESS.md`](KINDNESS.md)), said the way English
> says them, not carried over word by word.
>
> **Reader's problem (hypothesis; we haven't been able to ask yet):** "Is this a
> Mastodon clone with a Japanese skin?" "Why does it say 'this afternoon' instead of
> a time?" "Why is the terms page in a language I can't read?" If you read English and
> any of this felt wrong, please say so with "Send feedback" in the app.

Words live in `web-next/server/locales/en.ts` (and `en` in `extra.ts`). The language is
chosen as: the cookie from the language picker → the account's language → the browser's
`Accept-Language` → English if the browser named languages we don't have → Japanese if
it named none.

## How it sounds

- **Warm in sentences, plain on buttons.** "Welcome back." is a sentence. "Log in" is a
  button. A label says what it does; we don't put charm where someone is looking for the
  exit. (Japanese `入る` and Korean `들어가기` can be soft because the verbs are; English
  "Come in" on a login button makes people hunt.)
- **No baby talk, no cheering.** Japanese diminutives (`ちょこんと`, `お星さま`) don't have
  an English equivalent that doesn't read as twee. We keep one image on the front page
  ("a small star") and say the rest plainly.
- **No exclamation marks, no emoji in the interface.** "Received. Thank you." not
  "Thanks so much!!"
- **Errors say what happened and the next step, and never blame.** "That didn't go
  through. Try again?" "It's not your fault" appears only where it really isn't.
- **Contractions are fine; they're how a person speaks.** Curly apostrophes (’).
- **British spelling** (favourite, neighbour, recognise), as in the rest of the docs.
- **Say "no hurry" by what the screen does, not by saying it.** The one place we say it
  outright is the end of a list: "That's all, for now."

## Words we chose

| Japanese idea | English | Why |
| --- | --- | --- |
| 連合宇宙 | the fediverse | The word English readers already use. |
| お気に入り | favourite | What Mastodon apps call it. |
| ご近所 | Neighbours | The tab for servers the operator named as neighbours. |
| みんな | Everyone | The local timeline. |
| 合言葉 / あいことば | passphrase | Matches `USING.md`; it isn't a "password" we'd ask you to make hard. |
| お預かり | held | A post is *held* for a while after you send it; you can take it back. |
| 一刻 / 四半刻 | "about an hour" / "about a quarter of an hour" | The old unit has no English cousin; we keep the looseness. |
| ブースト | boost | The Mastodon word. |

## Time

We don't show clock times, and English keeps that: "this afternoon", "yesterday
evening", "the other morning", "an autumn night", "winter 2023".

- English readers live everywhere, so we don't assume a time zone. The browser
  tells us its zone in a small cookie (`sukhi_tz`, only the zone name, e.g.
  `Europe/London`); until it does, English shows UTC. Japanese and Korean fall back to
  Tokyo and Seoul as before, and use the cookie when it's there.
- Seasons flip for southern-hemisphere zones, so nobody reads "autumn" in spring.
- Names: we show the display name as given. We don't add "-san" / "님"; the English
  UI has no honorific to add.

## Not done yet (on purpose, or waiting for someone)

- **Terms and Privacy Policy are a translation of the Japanese.** Each says the Japanese
  text applies if the two differ. The English privacy policy also lists the language and
  time-zone cookies and says plainly that the handling is the same wherever you live;
  the Japanese and Korean pages haven't been given those two additions yet.
- **The `ui-lab` mocks and the guest-facing "first steps" / lobby copy** are still Japanese.
  When the lobby is built, write its English first lines with this page open.
- **Server-authored posts** (the neighbour guide, the official list title in `api/`)
  still pick between Japanese and Korean only.
- **Operator guides** (`*.ja.md`) have no English version; `docs/README.md` says so.
- **Other languages** (Italian, German and French are next, in that order) can copy this
  file's shape: a `locales/<xx>.ts`, a row in `time.ts`, a mail body in `email_auth.ex`.
