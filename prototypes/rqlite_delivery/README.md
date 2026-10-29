# rqlite_delivery — who delivers to which host (design + logic check)

Not wired into anything. `sim.py` runs `schema.sql` on plain SQLite (3.35+ for
`RETURNING`) to check the logic; `bench/` runs the same SQL against a real local
3-node rqlite v10.6.6 (see "Measured").

```
python3 -I sim.py      # 5 tests
```

## The assignment, in one paragraph

Hosts map to a fixed number of **buckets** (`hash(host) % 64`); that map never changes.
Each node heartbeats into `node`; the live set picks each bucket's owner by
**rendezvous hashing** — every node computes the same answer with no coordinator, and a
join/leave moves only ~1/N of the buckets (tested). A node takes a bucket with one
`UPDATE ... WHERE owner = me OR lease expired OR owner not live` and renews it by
heartbeat. `claim` is a single `UPDATE ... RETURNING` that only touches buckets whose
lease I hold *at that instant*, so a paused or partitioned ex-owner is fenced by the
statement itself (tested). One owner per bucket means one process sees all in-flight
jobs of a host, so the **per-host cap is a local counter**, not a distributed one.

When a node dies: its bucket leases lapse, the survivors take them (next tick), and
`lifeline` returns its leased jobs to `ready` (tested: redelivered with `attempt = 2`).
Delivery stays at-least-once; `delivery_receipts` still de-duplicates.

## What the tests cover

| test | property |
|---|---|
| exclusive claims | 3 nodes, 5000 jobs, interleaved: each job claimed exactly once, only from the claimer's buckets |
| fencing | an owner whose lease lapsed gets 0 rows from `claim`, the new owner gets rows |
| failover | jobs claimed by a dead node are claimed again by the new owner |
| rebalance | adding a node only moves buckets *to* it; removing one moves only *its* buckets |
| unique + retry | `INSERT OR IGNORE` de-dups; backoff then `dead`; the key is freed |

## Measured (rqlite v10.6.6, 3 nodes on one 4-vCPU box, one disk; HTTP over loopback)

```
rqlited -node-id n1 -http-addr 127.0.0.1:4011 -raft-addr 127.0.0.1:4012 \
        -bootstrap-expect 3 -join 127.0.0.1:4012,127.0.0.1:4022,127.0.0.1:4032 data/n1   # n2: 4021/4022, n3: 4031/4032
python3 -I bench/bench.py ; python3 -I bench/failover.py
```

| | result |
|---|---|
| single `INSERT` per request (one Raft commit) | 2.1 ms (about 480/s) |
| bulk load, 500 statements per request | about 35 000 rows/s |
| `claim`, 50 jobs per request (`UPDATE ... RETURNING`) | p50 4.1 ms, p99 6.4 ms, **about 11 700 jobs/s** |
| `complete`, 50 ids per request | 4.4 ms each, about 11 400 jobs/s |
| reads: `level=none` / `weak` / `strong` | 0.37 / 0.36 / 1.96 ms |
| RSS per node | 31-33 MB empty, 49-70 MB with 51 000 jobs |
| kill -9 the leader | writes succeed again via a follower after **2.6 s**; the node rejoins and catches up |

Caveats: all three nodes share one machine and one disk, so there is no network round
trip (a real deployment adds one per commit) but fsyncs contend; one client; no warm-up.

## Not covered

- Real network between nodes; 0.5 OCPU boxes; HA needs 3 voters.
- Clock skew: leases compare node-supplied `now`. rqlite can evaluate time on the leader
  (non-deterministic functions are rewritten), which would remove skew; verify.
- An Elixir HTTP client (Req is already a dependency) and the dispatcher loop.
