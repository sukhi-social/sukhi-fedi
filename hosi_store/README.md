# hosi_store

sukhi-fedi's data layer on [hosigraph](https://github.com/sukhi-social/hosigraph), written as parts
that are **not wired into `elixir/` yet**: a standalone mix project, outside `make test`, so
nothing in the gateway, delivery or api changes. Posts, boosts, likes, follows, notifications, the
timelines, deleting a post, closing an account (`AccountClosing`), and the Postgres side that stays
(delivery's outbox, read markers). It started as a spike (`sukhi-hosi-spike`).

Read `DESIGN.md` first: what moves and what stays in PostgreSQL, what each operation costs
(round trips, measured times), what is not read or built yet (§7, §11).

Switching over is by hand, one operation at a time (that is the decided shape); nothing here
does it.

## Running the tests

hosigraph-ex builds its NIF against libhosi (see its README, "Getting libhosi"). Point
`HOSIGRAPH_EX` at a checkout of `sukhi-social/hosigraph`'s `hosigraph-ex` (the default is
`../../hosigraph/hosigraph-ex`, a sibling of this repo).

```bash
HOSI_DTLV=/path/to/dtlv mix test                  # one dtlv process per call
HOSI_BACKEND=jvm HOSI_JAR=/path/to/datalevin-standalone.jar mix test   # a JVM that stays (JDK 21)
```

The tests that need PostgreSQL start the embedded PGlite from `../pglite` (`pnpm install` there
first); without node or its packages they are left out. `HOSI_PG_PORT=5432` uses a real
Postgres, which the two `:concurrent_pg` tests need.
