# hosi_store

sukhi-fedi's data layer on [hosigraph](https://github.com/sukhi-social/hosigraph): a standalone
mix project, outside `make test`. Posts, boosts, likes, follows, notifications, the timelines,
deleting a post, closing an account (`AccountClosing`), and the Postgres side that stays
(delivery's outbox, read markers). It started as a spike (`sukhi-hosi-spike`).

Only one part is connected to `elixir/`: `Tail` (with `Copy` and `Source`), which
`SukhiFedi.HosiMirror` runs to follow the store, off by default (`docs/HOSI.md`). The rest is
not wired: nothing in the gateway, delivery or api calls it.

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

The tests that need PostgreSQL start a throwaway pgrust server (`../scripts/pgrust-serve.sh`, which
fetches pgrust the first time); if it does not come up they are left out, and a line says why.
`HOSI_PG_PORT=5432` uses a Postgres you already have instead.
