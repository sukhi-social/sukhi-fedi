<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# hosigraph beside the store (the mirror)

> **Out of date.** `SukhiFedi.Repo` now *is* hosigraph (through `ecto_hosi`; see [`STORE.md`](STORE.md)), so this mirror,
> which copied a store into a second hosigraph, has nothing left to follow. It is kept until it is removed.

> **Intent:** say what the hosigraph mirror is, how to turn it on, and what it does
> and does not do, so a developer can try hosigraph as sukhi's data layer without
> risking the store that is running.
> **Reader's problem (hypothesis):** "I want to see our people and posts in
> hosigraph, without a switch-over I cannot undo. What is on, what is copied,
> what is not?"

## What it is

[hosigraph](https://github.com/sukhi-social/hosigraph) is a store of its own
(append-only, with erase/clean/freeze). `hosi_store/` holds sukhi's data layer on it as a
standalone mix project (`:sukhi_hosi`). `SukhiFedi.HosiMirror` is the one place that
connects it to the gateway: a process that **follows** `SukhiFedi.Repo` and copies the people
and the posts that are new into hosigraph, a little after they are written.

It follows; it does not sit in the write path. Nothing that writes a person or a post
changes, so a failure here is logged and never reaches the one who posted. A round that
fails is tried again on the next tick; where it got to is kept in hosigraph, and it moves
only past what is written.

**What is on screen still comes from the store.** hosigraph is read only to be compared with it, and only for the like view (see below).

## Turning it on

Off by default, in two ways. Both are needed.

| Where | Switch | What it does |
|---|---|---|
| build | `SUKHI_HOSI=1` | compiles `hosi_store/` in (`elixir/mix.exs`). Needs a checkout of `sukhi-social/hosigraph` (`HOSIGRAPH_EX` points at its `hosigraph-ex`, which builds or downloads libhosi). Changing it needs `mix compile --force`: mix does not see an env change. |
| run | `SUKHI_HOSI_MIRROR=1` | starts the follower. Without the build, it does nothing. |
| run | `SUKHI_HOSI_SHADOW=1` | also asks hosigraph the like view, to compare (below). Needs the follower. |

Where it keeps its files: `SUKHI_HOSI_DIR` (default `<DATALEVIN_DIR>/hosi`), on the
`dtlv` that `DATALEVIN_BIN` names. See [`ENV.md`](ENV.md).

The Dockerfile and CI do not build it yet, so a release does not have it.

## What is copied, and what is not

Copied: a person (`accounts`: ours as `https://<domain>/users/<username>`, a remote one by its
`actor_uri`), a post (`notes`, by `ap_id`, with its author, `published`, visibility, the HTML
to show, and for a reply its parent and thread root) and a like (a `reactions` row with the
favourite emoji, on the post, by the person). It works the same whichever store the Repo is on
(`SUKHI_STORE`), because it reads through Ecto.

Waits or gives up, by name (the round's report says which): a post whose author is
nowhere (`:no_author`); a local post that is still without its `ap_id` (waits up to 60
seconds, then `:no_ap_id`); a like whose post is not in hosigraph yet (waits up to 60 seconds,
then `:no_note`, in `likes_missing`).

What leaves the store is taken out of hosigraph by a sweep, the last step of a round: a post that
is gone from the store, and a favourite that was taken back. It looks at one window of the posts
hosigraph has (the newest first, 200 a time), asks the store which of them it still has and who
still likes them, and takes the rest away. It runs at most every 10 seconds, not on each 2-second
tick; a pass over every post takes (posts ÷ 200) × 10 seconds. A post taken away is a delete, not
an erase: its facts stay in the log.

The store is the truth for what is followed. When a kind of write moves to hosigraph, stop
following that kind first, or what only hosigraph has would look gone.

Not followed: edits, follows, boosts, any other reaction.

A person or post already in hosigraph is left alone (they are looked up by IRI), so a round that
stopped halfway is repaired by the next one.

## Comparing the like view

With `SUKHI_HOSI_SHADOW=1`, the two reads behind a status (`Notes.counts_for_notes`: how many
favourited it; `Notes.viewer_flags_many`: did the viewer) are also asked of hosigraph. The answer
is the store's, always. The mirror compares the two a moment later in its own process (hosigraph
is read where it is written, never at the same time), and drops the comparison when it is 50
behind: a shadow is not worth a queue.

It says nothing when they agree. When they differ, one line:

```
like shadow (favourites): 2 of 20 posts differ (hosigraph higher 1, lower 1), 3 not in hosigraph, question hash 1234567
```

The kind (`favourites` or `favourited`), how many posts differ and which way, how many posts
hosigraph does not have (an `info` line when that is all there is), and a hash of the question:
never the ids, which are people's posts. A quiet log means the ones asked agree; it does not
say how many were asked.

A difference that lasts a few seconds is not a fault: a favourite is followed a tick later
(2 seconds), or waits for its post (up to 60); a favourite taken back stays in hosigraph until the
sweep passes it (posts ÷ 200 × 10 seconds). One that stays is worth a look.

Not asked yet: the viewer's list of favourites, who favourited a post, the per-post
`counts_for_note` and `viewer_flags`, any reaction but the favourite.

hosigraph is not the answer for this because it is a little behind: the reply to a favourite
says `favourited`, and a reader that has just favourited must see `true`. That is for when the
writes move too.

## Checking it

```bash
# The mirror is off in a default build:
mix test test/sukhi_fedi/hosi_mirror_test.exs

# One round, Repo → hosigraph (pgrust + dtlv):
SUKHI_HOSI=1 HOSIGRAPH_EX=…/hosigraph-ex DATALEVIN_BIN=…/dtlv \
  scripts/test-pgrust.sh test/integration/hosi_mirror_test.exs
```

`hosi_store/`'s own tests (`mix test` there) cover the copying, the cursors, the three ways a
post can be passed over, and what the like view reads (`Notes.like_view/3`).

## Read next

[`../hosi_store/DESIGN.md`](../hosi_store/DESIGN.md) (ja): what moves and what stays in
PostgreSQL, what each operation costs, and what is not built or measured yet (§7, §11–13).
