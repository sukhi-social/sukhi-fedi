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

`mix compare` runs the same workload through `PushOrigin` (Mastodon-style
retries: `n^4 + 15` s plus jitter, 16 tries) and through the pull model
(`Origin` + `Puller`, direct messages still pushed), against one receiver B
with a work budget, a bounded queue and an optional outage
(`PullFederation.Compare`). Costs are assumptions, written in that
module: one HTTP request = 1 unit, storing one activity = 1 unit, B does
50 units/s. Numbers below are from this model, **not measurements**.

| Scenario | Model | Requests to B | Failed | Peak req/s | p50 latency | p99 latency |
| --- | --- | --- | --- | --- | --- | --- |
| steady, 60 posts at 1/s | push | 60 | 0 | 1 | 0 ms | 0 ms |
| | pull | 120 | 0 | 2 | 100 ms | 100 ms |
| burst, 500 posts from 20 origins in 5 s | push | 864 | 364 | 100 | 16.7 s | 55 s |
| | pull | 98 | 0 | 26 | 4.6 s | 12.8 s |
| same, 10% direct (push-only) | push | 864 | 364 | 100 | 16.7 s | 55 s |
| | pull | 132 | 0 | 31 | 4.9 s | 13.2 s |
| burst, requests cost 0.2 instead of 1 | push | 696 | 196 | 100 | 2.3 s | 17.4 s |
| | pull | 102 | 0 | 30 | 3.8 s | 11.9 s |
| burst, B has 4x capacity | push | 500 | 0 | 100 | 0 ms | 100 ms |
| | pull | 117 | 0 | 30 | 1.5 s | 3.1 s |
| B down for 30 s | push | 84 | 44 | 2 | 16 s | 55 s |
| | pull | 58 | 30 (all notifications) | 4 | 19.7 s | 41.9 s |

All activities were delivered in every run.

### What the model says

**Pull wins when B is the scarce side.** In the burst, push sends one
POST per activity, B's queue fills, 364 requests are rejected and the
retries land 16 s, 31 s, ... later, so p99 is 55 s. Pull sends 98
requests, none fail, and B decides the pace. The advantage shrinks as
requests get cheaper (row 4) and disappears once B has headroom (row 5).

**Push wins when nothing is wrong.** Steady traffic: push is 1 request
and ~0 ms per activity; pull is 2 requests (notification + pull) and adds
one tick plus the wait for B to be idle. If the notification quiet
period (`notify_quiet_ms`, 3 s) is hit, add up to that on top.

**Outage:** both recover. Push re-sends from per-job timers (no shared
state, no storm here because jitter is a hash of the id); pull loses the
notifications sent while B is down and relies on the recovery broadcast
(`Origin.recovered/2`), which is why the model includes it. Without the
broadcast the pull side would stay behind until the next new post.

### Pros and cons, as the prototype shows them

| | Push | Pull |
| --- | --- | --- |
| Latency in the good case | best: one hop | + notification, + wait for B to be idle, + quiet period |
| Requests in the good case | 1 per activity per domain | 2 per batch (cheaper only once batches have > 1 activity) |
| Burst / fan-in at B | B has no say; queue overflow becomes a retry storm | B sets the pace; declines and postpones are first class |
| Retry state | per activity per target, in A's queue (grows with outage length) | one cursor per actor in B; A keeps no per-target retry state |
| Failure repair | each activity retried until dropped (here after 16 tries) | cursor catches up from wherever it was, including after drops |
| Private / real-time | direct messages and anything urgent | not suitable; stays push |
| Moving parts | simple, well known | sequence ids, cursors, notification trust, decline protocol, log retention |
| Abuse surface | forged POSTs need a valid signature | forged notifications are cheap to send (bounded by the per-origin floor, but still B-side work) |
| Small servers | trivially implementable | extra endpoint, extra storage for a sequence index |

### Where the model is weak

- Costs are made up; the sensitivity rows show the result flips with
  them. Real numbers need measuring on a running instance.
- Only B is scarce. In reality A also pays for fan-out (signing, queueing
  thousands of jobs), which pull reduces; not modelled.
- Push is the ideal shared-inbox case: one POST per activity per domain.
- No log-retention limit on A, no Update/Follow/Undo, no real streaming.
- Jitter is deterministic, so synchronized retry storms across many B
  instances cannot appear.
