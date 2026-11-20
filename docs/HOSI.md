<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# hosigraph beside the store

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

**Nothing reads from hosigraph yet.** What is on screen still comes from the store.

## Turning it on

Off by default, in two ways. Both are needed.

| Where | Switch | What it does |
|---|---|---|
| build | `SUKHI_HOSI=1` | compiles `hosi_store/` in (`elixir/mix.exs`). Needs a checkout of `sukhi-social/hosigraph` (`HOSIGRAPH_EX` points at its `hosigraph-ex`, which builds or downloads libhosi). Changing it needs `mix compile --force`: mix does not see an env change. |
| run | `SUKHI_HOSI_MIRROR=1` | starts the follower. Without the build, it does nothing. |

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

Not followed: edits, deletes, a like taken back, follows, boosts, any other reaction. A post
deleted in the store stays in hosigraph, and so does a like taken back. Switching likes over
needs those followed first.

A person or post already in hosigraph is left alone (they are looked up by IRI), so a round that
stopped halfway is repaired by the next one.

## Checking it

```bash
# The mirror is off in a default build:
mix test test/sukhi_fedi/hosi_mirror_test.exs

# One round, Repo → hosigraph (PGlite + dtlv):
SUKHI_HOSI=1 HOSIGRAPH_EX=…/hosigraph-ex DATALEVIN_BIN=…/dtlv \
  scripts/test-pglite.sh test/integration/hosi_mirror_test.exs
```

`hosi_store/`'s own tests (`mix test` there) cover the copying, the cursors and the three ways a
post can be passed over.

## Read next

[`../hosi_store/DESIGN.md`](../hosi_store/DESIGN.md) (ja): what moves and what stays in
PostgreSQL, what each operation costs, and what is not built or measured yet (§7, §11–13).
