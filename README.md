<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi

[![CodSpeed](https://img.shields.io/endpoint?url=https://codspeed.io/badge.json)](https://app.codspeed.io/sukhi-social/sukhi-fedi?utm_source=badge)

A federated (ActivityPub) social server built to be calm: a place where you can
leave a few words, and drop by now and then, without hurry.
[sukhi.social](https://sukhi.social) runs on this software.

*(sukhi is made for Japan mainly. The screens are in Japanese, Korean and English. Some of
the operator guides under [`docs/`](docs/README.md) are in Japanese; the table of
contents says which.)*

## 1. What kind of place it is

We want staying long and just dropping by to both feel ordinary. So the screen
takes a few things on itself, ahead of you:

- **Posts don't go out at once.** For about a quarter of an hour (15 minutes) a
  post is "held". You can reread it, fix it, or take it back.
- **Reactions arrive in small batches.** Favourite and boost notifications wait a
  little, and come folded together. Replies and follow requests come right away.
- **No counts.** No favourite, boost or follower numbers; no unread numbers or
  badges. Nothing to compete over.
- **Time is told loosely.** "This afternoon", "last evening". Never minutes or seconds.
- **Lists end.** The last line says "That's all, for now." You may feel finished.

And a few promises we have made, which the screens have not fully caught up with yet:

- **Quieting things is as easy to find as blocking or reporting.**
- **Leaving is as easy as joining.** No reason asked. No attempt to keep you.

None of this is a technical limit. Every item is something we could do and
**chose to hold back**; the room it saves goes to keeping the server light and
long-lived. The thinking is in [`docs/KINDNESS.md`](docs/KINDNESS.md).

sukhi federates with the ActivityPub world: Mastodon, Misskey and others. It
speaks the Mastodon client API, so apps such as Elk, Phanpy, Ivory and Tusky work.
Add it to your home screen and it opens like an app.

## 2. Start using it

- To look around: [about.sukhi.social](https://about.sukhi.social).
- Joining, writing, notifications, moving in and out, leaving:
  [`docs/USING.md`](docs/USING.md) ([日本語](docs/USING.ja.md)).
- If something went wrong, or you wish for something, use "Send feedback" in the app.
  We may not be able to reply, but it is read.

## 3. Run your own server

Anyone can run sukhi. A server is also something you keep **in trust** for other
people, so there is no hurry. If you don't have the hands for it, there is a path
without running one (we are thinking about small communities inside sukhi.social).

- The way in is [`docs/OPERATIONS.ja.md`](docs/OPERATIONS.ja.md): prepare, first
  start, daily care, in that order. **The operator guides are in Japanese only; there
  is no English version yet.**
- [`docs/CARING_FOR_YOUR_SERVER.ja.md`](docs/CARING_FOR_YOUR_SERVER.ja.md) (Japanese) is how
  to look after it without being frightened.
- To just try it on your own machine: "Run it locally" in
  [`docs/DEVELOPING.md`](docs/DEVELOPING.md). `make dev` alone starts it, no Docker.

## 4. Building it

Design, specifications, environment variables and tests: the table of contents is
[`docs/README.md`](docs/README.md). If you are unsure where to start:

1. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the shape of the whole (canonical).
2. [`docs/CODE_STYLE.md`](docs/CODE_STYLE.md) — keeping security and speed in the structure.
3. [`docs/DEVELOPING.md`](docs/DEVELOPING.md) — run it, test it, who we learned from.

## Keeping it going

sukhi is kept going by one person's hands and by the support people give.
How to support it, and what it is spent on, is at
[about.sukhi.social/en/support](https://about.sukhi.social/en/support/).
What you can do here is the same whether or not you support it.

## License

AGPL-3.0-or-later ([`LICENSE`](LICENSE)). The dependency
[ojak-ex](https://github.com/sukhi-social/ojak-ex) is AGPL-3.0-only; what to know
before using it is in [`docs/DEVELOPING.md`](docs/DEVELOPING.md).
