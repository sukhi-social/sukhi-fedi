# Pull Federation prototype

A runnable model of the "Pull Federation" idea: instance A *notifies*
with per-actor sequence ids, instance B *pulls* lazily when it has room.
No network, no deps, no clock: every function takes `now` (ms), so the
whole protocol is deterministic and unit-testable.

```
mix test
```

(Elixir 1.20 / OTP 28, same as the repo's `mise.toml`.)

## Spec step → code

| Step | Where |
| --- | --- |
| 1. A has new activities, B follows the actors | `Origin.publish/3`, `Origin.follow/3` |
| 2. Notify with `[a:123, b:124]` | `Origin.due_notifications/2` (only actors that domain follows) |
| 3. Compare with own ids, plan if different | `Puller.notify/4` → `Seq.behind/2` |
| 4. Busy → postpone | `Puller.next_pull(_, _, busy?)` |
| 5. Pull when scheduled | `Puller.next_pull/3` |
| 6. A busy → decline | `Origin.open_stream/4` → `{:error, {:busy, retry_ms}}`; B backs off with jitter in `finish_pull/5` |
| 7. Stream of relevant activities | `Origin.open_stream/4` returns events past B's cursors |
| 8. B verifies signatures | `Puller.apply_activity/3` calls the injected `verify` |
| 9. A waits a few seconds before the next notification | `notify_quiet_ms` coalescing |

## Decisions the prototype makes (all easy to change)

- **Sequence = index of what is visible.** Per actor there are two
  integer sequences from 1: the *public* index (public + unlisted, key
  = the actor URI) and the *followers* index (key = `actor#followers`).
  Direct messages are push-only and touch neither, so a gap never
  reveals a hidden activity, and the public index is just a number any
  reader could already derive from the public outbox.
- **Sequence ids, not hashes or dates.**
- **Notifications are untrusted.** Shape-checked once (`Seq.parse/1`, ≤1000 entries),
  actors B does not follow are dropped, and a per-origin floor
  (`min_notify_gap_ms`, 1000) rate-limits them. Authenticity is meant
  to be the OIP/signature layer; here it is the injected `verify`.
- **Bounded pool.** `max_pending` origins; a full pool drops *new* origins
  but still merges updates for origins already queued.
- **Both ways for Delete.** Push and pull go through one function
  (`apply_activity/3`). A Delete leaves a tombstone, so a Create that
  arrives afterwards (by either path) is ignored; duplicates are no-ops.
- **Reverse-DDoS control.** A declines with `retry_after`; B uses
  `max(retry_after, exponential backoff) + jitter`.
  `Origin.recovered/2` is the "I'm back" broadcast, spread by a jitter fn.
- **Cursor moves per event**, so an interrupted stream resumes where it stopped.

## Not modelled yet

- Real HTTP / streaming (NDJSON or chunked) and HTTP-signature verification.
- Log retention: if B's cursor is older than what A kept, A needs a
  "cursor too old, fall back to outbox crawl" answer.
- Update / Follow / Undo semantics over pull (only Create / Delete here).
- PostgreSQL shape (e.g. one `bigserial` per actor via an `(actor_id, seq)`
  unique index, stream = `WHERE seq > $cursor ORDER BY seq`).
- Choosing push vs pull per target from metrics.

## Push vs pull: the comparison

`mix compare` runs the same workload through both models, in two parts.
All numbers come from a model with made-up unit costs (listed in the
module docs), **not measurements**; the structs do the counting, the cost
tables turn counts into units.

### Part 1: the receiver B (`PullFederation.Compare`)

One receiving instance with a work budget (50 units/s), a bounded queue
and an optional outage. A request costs 1, a database query costs 0.5,
handling an activity in memory costs 0.5. Push is one request and two
queries per activity (dedupe lookup, insert). Pull is one request and
four queries *per batch* (cursor read, batched dedupe, multi-row insert,
cursor write), so the database cost is paid once per stream, not once per
activity.

| Scenario | Model | Requests to B | Failed | Peak req/s | p50 | p99 |
| --- | --- | --- | --- | --- | --- | --- |
| steady, 60 posts at 1/s | push | 60 | 0 | 1 | 0 ms | 0 ms |
| | pull | 120 | 0 | 2 | 100 ms | 100 ms |
| burst, 500 posts from 20 origins in 5 s | push | 930 | 430 | 100 | 18 s | 55 s |
| | pull | 99 | 0 | 25 | 3.2 s | 10.5 s |
| same, 10% direct (push-only) | push | 930 | 430 | 100 | 18 s | 55 s |
| | pull | 130 | 0 | 29 | 4.9 s | 11 s |
| burst, requests cost 0.2 | push | 808 | 308 | 100 | 16 s | 55 s |
| | pull | 105 | 0 | 30 | 2.6 s | 8.9 s |
| burst, B has 4x capacity | push | 511 | 11 | 100 | 0.7 s | 16 s |
| | pull | 118 | 0 | 30 | 1.5 s | 3 s |
| B down for 30 s | push | 84 | 44 | 2 | 16 s | 55 s |
| | pull | 58 | 30 (all notifications) | 4 | 19.7 s | 41.9 s |

All activities were delivered in every run. With the database in the
bill, pull's batched queries make each stored activity cheaper, so in
the burst it wins at p50 and p99 (3.2 s vs 18 s at p50). With 4x
capacity the picture is mixed: push is faster at p50 (0.7 s vs 1.5 s) but
still has 11 rejected requests and a 16 s p99, against 3 s for pull. In
steady state push still wins: 1 request and ~0 ms against 2 requests and
a tick.

### Part 2: the origin A, fan-out (`PullFederation.FanOut`)

One popular actor on A, followed from D remote domains, posting P
activities in 10 s. `PushOrigin` makes the jobs, `Origin` decides the
notifications (quiet period 3 s); pull assumes every notified domain
pulls at once, which is the worst case for A. 5% of push first tries are
retried. Costs: sign 3, send 1, verify 0.3, row write 1, indexed query 2,
row read 0.05, serialize 1.

| D domains | P posts | Model | Outbound reqs | DB writes | Peak queue | MB out | Cost units |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 100 | 10 | push | 1,050 | 2,100 | 1,000 | 2.9 | 6,410 |
| | | pull | 400 (+400 inbound) | 10 | 100 | 2.7 | 3,240 |
| 1,000 | 10 | push | 10,500 | 21,000 | 10,000 | 29 | 63,560 |
| | | pull | 4,000 (+4,000 inbound) | 10 | 1,000 | 27 | 31,950 |
| 1,000 | 100 | push | 105,000 | 210,000 | 100,000 | 294 | 635,600 |
| | | pull | 5,000 (+5,000 inbound) | 100 | 1,000 | 209 | 53,500 |
| 5,000 | 100 | push | 525,000 | 1,050,000 | 500,000 | 1,470 | 3,175,600 |
| | | pull | 25,000 (+25,000 inbound) | 100 | 5,000 | 1,045 | 265,500 |

Push's cost per post is `D x (sign + send + 2 writes)`; it is linear in
both domains and posts. Pull's is `D x (notifications per window)` and
does not depend on the number of posts inside a quiet window, so more
posts per window make it relatively cheaper (12x at 100 posts, 5000
domains; only 2x at 10 posts). The database story on A is the biggest
single difference: push writes a job row (or Redis entry) and an ack per
target per activity; pull writes one index row per activity and serves
reads from an indexed range scan on `(actor_key, seq)`.

### What the model says

**Pull wins when either side is the scarce one.** B's queue overflows
under push in a burst (retry storm, p99 55 s). A's job queue under push
holds `D x P` entries at once (100,000 at 1,000 domains and 100 posts);
under pull A holds one dirty entry per domain. Part 2 is why this idea
exists: fan-out is O(D x P) for push and O(D x windows) for pull.

**Push wins when nothing is wrong and traffic is light.** One request,
no extra state, minimum latency. At low post rates pull's notification +
pull pair costs more than just sending (10 posts: pull is only 2x
cheaper at A, and slightly worse than push for B in steady state).

**Outage:** both recover. Pull loses notifications sent while B is down
and relies on the recovery broadcast (`Origin.recovered/2`).

### Pros and cons, as the prototype shows them

| | Push | Pull |
| --- | --- | --- |
| Latency, good case | best: one hop | + notification, + wait for B to be idle, + quiet period |
| Requests, good case | 1 per activity per domain | 2 per batch (only cheaper once batches hold > 1 activity) |
| Origin fan-out | O(D x P) jobs, signatures, DB writes | O(D x windows); 1 index write per activity |
| Origin database | job row + ack per target per activity (or Redis equivalent) | one sequence row per activity, range scans on read |
| Receiver database | 2 queries per activity | 4 queries per batch |
| Burst / fan-in at B | B has no say; overflow becomes a retry storm | B sets the pace; declines and postpones are first class |
| Retry state | per activity per target, in A (grows with outage length) | one cursor per actor in B; A keeps none per target |
| Failure repair | each activity retried until dropped | cursor catches up from wherever it was, including after drops |
| Private / real-time | direct messages and anything urgent | not suitable; stays push |
| Moving parts | simple, well known | sequence ids, cursors, notification trust, decline protocol, log retention |
| Abuse surface | forged POSTs need a valid signature | forged notifications are cheap to send (bounded by a per-origin floor, still B-side work) |
| Small servers | trivially implementable | extra endpoint and a sequence index |

### Where the model is weak

- All costs are made up; rows 4-5 of part 1 show how far the answer moves
  with them. Real numbers need measuring on a running instance.
- Pull's origin side counts a stream read as one indexed query. A real
  Postgres would need the index kept hot and the log kept long enough
  (retention is not modelled), and a hot actor's index becomes a
  contention point for the sequence counter (one counter per actor and
  index, written once per activity).
- Push is the ideal shared-inbox case, one job per domain; a server that
  fails to dedupe by shared inbox is far worse.
- The `D x windows` bound for pull needs each domain to pull once per
  notification; B instances that skip notifications make A cheaper still.
- No Update/Follow/Undo, no real streaming, deterministic jitter (no
  synchronised retry storms across many B instances).
