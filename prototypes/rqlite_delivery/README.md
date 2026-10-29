# rqlite_delivery — who delivers to which host (design + logic check)

Not wired into anything, and **never run against rqlite**: the sandbox refused to start
the downloaded `rqlited` binary, so `sim.py` runs the same SQL on plain SQLite
(3.35+ for `RETURNING`; rqlite is SQLite behind Raft, one statement = one commit).
It checks the logic, not rqlite's latency, throughput or memory.

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

## Not covered (needs the real thing)

- rqlite latency/throughput: every write is a Raft commit on the leader. Claims should be
  batched (`LIMIT :n`) and `complete`/`fail` batched too.
- Memory/disk of a 3-node cluster on small boxes; HA needs 3 voters.
- Clock skew: leases compare node-supplied `now`. rqlite can evaluate time on the leader
  (non-deterministic functions are rewritten), which would remove skew; verify.
- An Elixir HTTP client (Req is already a dependency) and the dispatcher loop.
