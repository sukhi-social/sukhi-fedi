# Pull Federation prototype

A runnable model of the "Pull Federation" idea: instance A *notifies*
with per-actor ETags, instance B *pulls* lazily when it has room.
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
| 3. Compare with own ids, plan if different | `Puller.notify/4` → `Cursors.changed/2` (token differs?) |
| 4. Busy → postpone | `Puller.next_pull(_, _, busy?)` |
| 5. Pull when scheduled | `Puller.next_pull/3` |
| 6. A busy → decline | `Origin.request_stream/4` → `{:error, {:retry_at, ms}}` (an appointment) or `{:busy, ms}`; B waits exactly that, or backs off with jitter (`finish_pull/5`) |
| 7. Stream of relevant activities | `Origin.open_stream/4` returns events past B's cursors |
| 8. B verifies signatures | `Puller.apply_activity/3` calls the injected `verify` |
| 9. A waits a few seconds before the next notification | `notify_quiet_ms` coalescing |

## Decisions the prototype makes (all easy to change)

- **ETag per index; ordered where the count is public, opaque where it
  is not.** The origin keeps two counters per actor: the *public* index
  (public + unlisted, key = the actor URI) and the *followers* index
  (key = `actor#followers`). The public index's token is its sequence
  number (`s.<n>`): that count is already readable from the public outbox,
  and an ordered token lets B drop a stale notification and lets A answer
  "everything after n" exactly. The followers index's token is 12 random
  bytes stored on the event (`o.<random>`): no secret, nothing derived
  from the counter, so a locked account's activity cannot be read off it.
  Direct messages are push-only and touch neither index. B never needs to
  parse a token beyond "does it start with `s.`" (see `Etag`).
- **Pull sends only what changed.** B's request carries the tokens it
  holds; the stream returns only the keys whose token differs, with the
  new token on every event (so an interrupted stream resumes at the
  right place). A token the origin does not recognise (too old, forged)
  gets a replay of what it still keeps; applying is idempotent.
- **Notifications are untrusted.** Shape-checked once (`Cursors.parse/1`, ≤1000 entries, token ≤64 bytes),
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
- PostgreSQL shape (e.g. an internal `bigserial` per actor via an `(actor_id, seq)`
  unique index, stream = `WHERE seq > $cursor ORDER BY seq`).
- Choosing push vs pull per target from metrics.

## Push vs pull: the comparison

`mix compare` runs the same workload through both models, in two parts.
All numbers come from a model with made-up unit costs (listed in the
module docs), **not measurements**; the structs do the counting, the cost
tables turn counts into units.

### Summary: the current design against push

"Current design" = per-actor ETag notifications (ordered `s.<n>` for the
public index, opaque for followers-only), inline by default, pull of only
the changed keys, DMs still pushed. Same workloads, same made-up costs.

| Question | Push | Pull (current) | Winner |
| --- | --- | --- | --- |
| Quiet traffic, latency | ~0 ms, 1 request per post | +100 ms, 2 requests per post | push |
| 500-post burst from 20 origins: requests to B | 930 (430 rejected) | 99 (0 rejected) | pull, 9x fewer |
| same, p50 / p99 latency | 18 s / 55 s | 3.2 s / 10.5 s | pull |
| same with B at 4x capacity, p50 / p99 | 0.7 s / 16 s | 1.5 s / 3 s | push at p50, pull at p99 |
| B down 30 s, p99 | 55 s | 42 s (needs the recovery broadcast) | pull, slightly |
| Origin cost, 1,000 domains x 100 posts | 635,600 units, 210,000 DB writes | 53,500 units, 100 DB writes | pull, 12x |
| Origin cost, 1,000 domains x 10 posts | 63,560 units | 31,950 units | pull, 2x |
| Origin queue depth, same 1,000 x 100 | 100,000 jobs | 1,000 dirty domains | pull |
| Leak surface | none new | public count (already public); followers index opaque | tie |
| Implementation weight | small | cursors, tokens, decline protocol, resync | push |

In short: push is the right default for low rates and urgent or private
traffic; pull earns its complexity at bursts (receiver) and at large
follower-domain counts (origin). The two weak spots of pull are the
quiet-traffic overhead (twice the requests) and recovery after an outage
(it needs the "I'm back" broadcast, because a notification is lost when B
is down and nothing else repeats it).

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
| same, 40% followers-only (opaque tokens) | push | 930 | 430 | 100 | 18 s | 55 s |
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

### Part 3: how the notification is shaped (`PullFederation.NotifyCost`)

A notification can carry the changed ETags inline (`%{key => etag}`,
only the actors that changed, per domain) or point at **snapshot
buckets**. Snapshots use the sccache layout, first two hex characters /
next two / hash (`PullFederation.Snapshot`):

    <base>/ab/cd/<sha256(actor uri)>    one actor's public ETag
    <base>/ab/_index                    bucket `ab` (256 of them): version + every actor in it

Both sides derive the path from the actor URI, so a notification only
carries bucket versions. Only the public index is ever put in a snapshot;
followers-only counters stay inline and go to followers' domains alone.
Actors with no remote follower never bump a bucket. `Origin.inline_max`
(default 5) is the hybrid switch: at most that many changed public actors
travel inline, more become bucket versions.

Measured on the real `Origin`/`Puller` logic (seeded, bytes are payload
sizes, see the module for the unit sizes):

| Setup | Form | Notifications | Avg notification | B's snapshot GETs | Snapshot bytes | A renders | Total wire bytes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| each of 200 domains follows 100 of 2,000 actors, 200 posts | inline | 657 | 248 B | 0 | 0 | 0 | 163,522 |
| | hybrid (<=5 inline) | 657 | 248 B | 7 | 504 | 7 | 163,890 |
| | always snapshot | 657 | 218 B | 1,017 | 96,768 | 100 | 240,372 |
| each of 100 domains follows 1,500 of 2,000, 1,000 posts | inline | 500 | 665 B | 0 | 0 | 0 | 332,671 |
| | hybrid | 500 | 376 B | 6,778 | 571,104 | 91 | 759,179 |
| | always snapshot | 500 | 367 B | 6,996 | 588,600 | 92 | 772,552 |

**Result: the snapshot form does not pay for itself on the wire.** The
inline form only lists actors that changed for that domain, so it stays
small (248-665 B) even when the domain follows 1,500 actors. A bucket
document lists *every* actor in the bucket, and a domain that follows
many actors touches most of the 256 buckets, so B fetches around 14
documents per notification. Notifications shrink by more than half, total
traffic more than doubles. What snapshots do buy is origin work: 92 renders for 500
notifications (each bucket version is rendered once and then served from
a cache), against building each notification from the counters. That is
worth it only if building notifications is itself a bottleneck on A, which
the part 2 numbers do not suggest (notifications are a small share).

So the default stays **inline**; the snapshot path is an escape hatch for
the rare notification that would otherwise list hundreds of actors. A
sensible `inline_max` is therefore much larger than 5 (hundreds), which
is a parameter, not a code change. Per-actor documents at `ab/cd/<hash>`
are the natural layout for the thing snapshots are *clearly* good at:
a B that was away or lost notifications re-checking the actors it follows
with conditional GETs (304 when unchanged), served by any static host.
That path is not built here.

### Part 4: ETags on the wire (the current format)

A tells B, "as far as I know these actors you follow have changed", with
one token per actor (`key => etag`). If it is news, B pulls with the
tokens it holds (like `If-None-Match`) and A answers **only for keys whose
token changed**, each event carrying its new token.

Two kinds of token (`Etag`), chosen by the origin per index:

| | ordered `s.<n>` (public index) | opaque `o.<random>` (followers index) |
| --- | --- | --- |
| What it is | the sequence number | 12 random bytes stored on the event |
| B can | compare: ignore a stale one, never rewind a cursor | test equality only |
| A answers a cursor | exactly ("after n"), no log lookup | by finding the token among events it holds; unknown token = replay |
| Reveals | the public count (already public) | nothing |
| Key to keep | none | none (no HMAC, so nothing to rotate) |

A timestamp would also work as an ordered token, but is worse than the
counter: it reveals when the actor is active, two events can share a
millisecond, and a clock step backwards breaks the order.

What the prototype found along the way:

- **Opaque tokens alone cannot be ordered, and that broke pulling.** The
  first all-opaque version re-pulled forever in the burst scenario (3,882
  requests instead of 99, activities not all delivered), because a
  notification carrying an older token than the stream's state stayed
  "pending" for good. Two fixes remain in the code: `Puller.begin_pull/2`
  remembers what was pending when a pull starts and drops, after the
  stream, every entry that has not changed since (so a late stale opaque
  notification costs exactly one empty pull, and news that arrives mid-pull
  is kept); and ordered tokens make the problem disappear for the public
  index, where a stale notification is ignored with no pull at all. All of
  these are tests.
- **Resync is explicit for opaque tokens.** An unrecognised token means
  "replay what you keep" (counted in `Origin.resyncs`), and applying is
  idempotent. For an ordered cursor the origin answers precisely.
- **Notification size** with real token lengths: 248-665 B on average in
  the setups above (an `s.12` entry is smaller than a random one).

Parts 1 and 2 were re-run on this version and are unchanged: they count
requests and queries, not token bytes.

### Part 5: hostile traffic (`PullFederation.Flood`)

Both run with `mix compare` and are tests (`test/flood_test.exs`).

**Forged notifications, aimed at B.** Authenticity of the sender (OIP,
signatures) is assumed here, not modelled; these cases are about what a
forged or flooding notification can *cost*.

| Attack | Accepted | Pulls it caused | B's state growth |
| --- | --- | --- | --- |
| 11 malformed shapes (wrong types, bad tokens, negative numbers) | 0 / 11 | 0 | 0 |
| oversize maps (1,001 entries; 257 buckets) | 0 / 2 | 0 | 0 |
| 10,000 notifications from 10,000 invented origins | 0 / 10,000 | 0 | 0 |
| 1,000 actors B does not follow, from a known origin | 0 / 1 | 0 | 2 entries |
| 10,000 random-token notifications in 10 s from a known origin | 10 / 10,000 | 10 (all empty; the real post is delivered once) | 2 entries |
| forged `s.999999999`, then a real update | 2 / 2 | 1 | the real update is still seen; cursor not poisoned |
| bucket versions for all 256 buckets | 1 / 1 | 0 | fetches only the 1 bucket B follows |

The first run found a real hole: a notification from an origin B follows
nobody on still wrote that origin into B's tables, so 10,000 invented
names meant 10,000 entries. `Puller.notify/4` now refuses unknown origins
before touching any state. Everything else was already bounded: the
per-origin floor (1 s) caps the work of a flood at one empty pull per
second, and a cursor only ever moves from the origin's real answer, never
from a notification, so a forged future token cannot hide real news.
`state_growth` is one table entry per *known* origin, which is bounded by
the follow list.

**Pull stampede, aimed at A.** One post, D domains all want it at once.
8 stream slots, 400 ms per stream (20 admissions/s at best), a decline
costs A 1.3 units (verify + send), an admitted pull 3.3.

| Setup | Requests at A | Per domain | p50 / last converged | Cost |
| --- | --- | --- | --- | --- |
| 1,000 domains, receivers guess a backoff (jitter) | 4,424 | 4.4 | 85 s / 220 s | 7,751 |
| same, no jitter | 5,880 in 300 s | n/a | **48 of 1,000 converged after 300 s** | 7,740 |
| 1,000 domains, **appointments** | 2,048 | 2.0 | 31 s / 63 s | 4,662 |
| same + receivers start lazily over 30 s | 2,002 | 2.0 | 32 s / 63 s | 4,603 |
| 5,000 domains, guess | 31,941 | 6.4 | 361 s / 879 s | 51,515 |
| 5,000 domains, **appointments** | 10,279 | 2.1 | 157 s / 315 s | 23,363 |
| 1,000 receivers hammering every 100 ms, ignoring promises | 311,797 in 63 s | 312 | 31 s / 63 s | 407,336 |

What it shows:

- **A never runs more than its slots** in any row (`peak_active_streams`
  is 8 everywhere). Admission is the one place that decides.
- **Guessing a backoff is the wrong answer.** Receivers back off
  exponentially, but the origin's slots sit idle in between, and without
  jitter every receiver retries in the same wave: 48 of 1,000 converged in
  300 s. The fix is on the origin: when no slot is free it hands out the
  next appointment, one per `slot_ms` (stream time / slots), as
  `{:retry_at, ms}` (`Origin.request_stream/4`). The receiver waits
  exactly that. State is one counter plus one entry per waiting domain;
  past `max_reserve_ms` (300 s) it stops promising and sheds with
  `{:busy, ms}`, and a domain that comes back early is turned away without
  consuming another slot of the calendar. Requests per domain fall from
  4.4 (6.4 at 5,000) to 2.0 and convergence is 3.5 times earlier at p50
  (31 s against 85 s). The full design, rules, failure modes and the two
  bugs found on the way are in [RESERVATIONS.md](RESERVATIONS.md).
- **The 315 s for 5,000 domains is capacity plus headroom, not protocol:** 20
  admissions per second need 250 s, and the book is filled to 80%. A real small stream finishes faster than 400 ms;
  `stream_ms` is a parameter.
- **The first second is the same for everybody** (every receiver asks once,
  peak 1,000/s) unless receivers start lazily: spreading their first pull
  over 30 s cuts the peak to 74/s. That is the "B has the right to pull
  lazily" idea, and it is the only thing that helps with the first wave.
- **Hammering cannot be fixed by the protocol.** Receivers that ignore
  declines turn 1,000 domains into 311,797 requests (407,336 units against
  4,662), and `min_pull_gap_ms` adds nothing once appointments are on,
  because early arrivals are already turned away. They do not displace
  anybody's appointment, which is what the calendar guarantees. A decline is cheap but
  not free, so this is an edge problem: per-IP rate limiting and answering
  429 before the signature check, as for any public endpoint. It is not
  worse than push, where the same attacker could POST an inbox; but pull
  adds a read-shaped, database-touching endpoint, so the admission checks
  run cheapest first (known domain, appointment, gap, slot) and nothing
  touches the database until a slot is granted.

Caveats: authenticity is assumed; the stream time is a constant; there is
no network latency; `max_reserve_ms`, `slot_ms` and the slot count are
tuning knobs I did not tune.

### Part 6: which actors should be pushed and which pulled

The question: does it depend on how often an actor posts, how many
followers it has, or both? (`FanOut.per_domain/3`, quiet period 3 s,
costs as in parts 1 and 2.)

**What decides it is how many posts reach one receiving domain per
notification window, not the follower count and not one actor's rate.**
Per follower domain the origin pays, for push, `sign + send + 2 writes`
per post; for pull, one notification and one stream per *window*. The
number of domains multiplies both sides (almost exactly: serializing and
signing the activity once is a small part that does not scale), so it
scales the absolute bill but does not move the break-even. And the window is per origin: a
notification and a stream cover every actor of that origin the domain
follows, so fifty actors posting once a minute each look like one actor
posting almost once a second. That answers "pulling several actors at
once": yes, it matters, and it moves small-but-chatty origins towards pull.

Per follower domain, 10 minutes, even pace:

| Posts that domain follows on this origin | Posts per notification | Origin push / pull cost | Receiver push / pull cost | Cheaper |
| --- | --- | --- | --- | --- |
| 1 | 1.0 | 0.9x | 0.5x | push |
| 10 | 1.0 | 0.8x | 0.5x | push |
| 100 | 1.0 | 0.8x | 0.5x | push |
| 200 (one per 3 s) | 1.0 | 0.8x | 0.5x | push |
| 300 (one per 2 s) | 1.5 | 1.2x | 0.8x | origin: pull, receiver: push |
| 400 | 2.0 | 1.6x | 1.0x | pull (receiver: even) |
| 600 (one per second) | 3.0 | 2.2x | 1.3x | pull |
| 2,000 | 10.0 | 4.9x | 2.5x | pull |

(`x` = push cost divided by pull cost; below 1.0 push is cheaper.)

Below roughly one post per quiet period every post needs its own
notification *and* its own pull, so pull does the same work in two
requests and loses by about 20% at the origin and by half at the
receiver. Above it the batches form. A longer quiet period moves the
break-even down and the latency up: with 10 s, 200 posts per 10 min
already batch 3.3 to 1 (origin 2.3x, receiver 1.4x). With 1 s the
break-even is 1,200 posts per 10 min.

So, for the four corners:

| | Posts rarely | Posts a lot |
| --- | --- | --- |
| **Few followers** | push; the difference is a fraction of a cent either way | pull is cheaper per domain, but with 5 domains the absolute saving is small (600 posts per 10 min: 11,000 units saved on 5 domains, 11 million on 5,000). Push is fine, pull is optional |
| **Many followers** | push; pull is about 20% worse per domain and gains nothing. The one burst to watch is a single post that creates `D` jobs at once | pull: the largest absolute saving, and it removes the `D x P` job queue (1,000 domains x 100 posts: 100,000 queued jobs against 1,000 dirty entries) |

Two things the corners hide: the cost of pull's complexity is paid once
per origin, not per actor, so "which actors" is really "which
(origin, receiving domain) pairs"; and a receiver being overloaded or an
origin being in a burst (parts 1 and 5) can justify pull even at a low
average rate, because averages hide the peak.

That points at a rule a program can evaluate per (origin, domain):
use **push by default; switch that domain to notify-and-pull when its
recent posts per quiet window exceed about 1.5, or when it answered
429/5xx recently; switch back when the rate falls**. Directs and anything
urgent stay push regardless. The switch is built (`Mode`, part 7); the numbers above are what its
thresholds come from.

### Part 7: the hybrid (push by default, pull when it gets dense)

`PullFederation.Mode` decides per (origin, receiving domain) and nowhere
else. It starts on push; it goes to pull when posts reaching that domain
reach 1.5 per 3 s window (two posts inside one window are enough, no wait
for the average) or when a push to it failed; it comes back only after the
windowed average stayed under 0.7 for 30 s and the failure penalty (60 s)
is over. The gap between 1.5 and 0.7 plus the hold is the hysteresis.

What makes mixing safe is that **the origin always appends to the log
and assigns the ETag**, whichever way a domain is served. A push carries
the chain token: `%{key, etag, prev, activity}`. The receiver
(`Puller.receive_push/4`) runs it through the same `apply_activity` as a
pulled one, then:

- it holds exactly `prev`: advance the cursor to `etag`, no pull needed;
- it holds `etag` or something newer: nothing to do;
- anything else: it missed something, so plan a pull for that key.

A push that fails (429, 5xx, timeout) is **not retried**. The activity is
already in the log, so `Origin.push_failed/4` moves the domain to pull and
marks it, and the next notification carries it. That removes push's retry
storm (the `n^4` schedule of part 1) from the picture.

Same workloads as part 1, one more row each:

| Scenario | Model | Requests to B | Failed | p50 | p99 |
| --- | --- | --- | --- | --- | --- |
| steady, 60 posts at 1/s | push | 60 | 0 | 0 ms | 0 ms |
| | pull | 120 | 0 | 100 ms | 100 ms |
| | **hybrid** | **60** | 0 | **0 ms** | **0 ms** |
| burst, 500 posts from 20 origins in 5 s | push | 930 | 430 | 18 s | 55 s |
| | pull | 95 | 0 | 3.2 s | 10.4 s |
| | **hybrid** | 108 | 0 | 3.9 s | 10.8 s |
| mixed: 18 quiet origins + 2 bursting | push | 391 | 11 | 0.7 s | 16.1 s |
| | pull | 372 | 0 | 1.0 s | 4.3 s |
| | **hybrid** | **194** | 0 | 0.9 s | 4.5 s |
| burst, B has 4x capacity | push | 511 | 11 | 0.7 s | 16 s |
| | pull | 116 | 0 | 1.5 s | 3 s |
| | **hybrid** | 132 | 0 | 1.4 s | 3 s |
| B down for 30 s | push | 84 | 44 | 16 s | 55 s |
| | pull | 58 | 30 | 19.7 s | 41.9 s |
| | hybrid | 52 | 34 | 19.7 s | 41.9 s |

What it shows: the hybrid gets push's numbers when nothing is going on
(60 requests, 0 ms), pull's numbers in a burst (no rejected request, a
tenth of push's requests), and in the mixed case it beats both on
requests (194 against 391 and 372) because the 18 quiet origins stay on
push while the 2 bursting ones are on pull. The cost is a little in the
burst itself (108 requests against 95, p50 3.9 s against 3.2 s): the first
two posts of each burst still go out as pushes before the switch.

Not yet covered: a domain flapping on a noisy boundary (the unit tests
cover the hysteresis, not an adversarial rate), the mode state's memory
(one small record per known domain), and the receiver telling the origin
"pull me" explicitly (it only learns by failures today).

### Part 8: RTT, and whether reservations are needed day to day

"Ping" is read here as network round-trip time (RTT). `Compare` and
`Flood.stampede` take `rtt_ms`; a message takes half of it each way.

**Normal traffic never touches the calendar.** In every uncontended
scenario (steady, mixed quiet origins) pull and hybrid show `booked=0`
and `declines=0`; a test pins this (`appointments_booked == 0`). An
appointment is only written when an origin refuses a stream, which only
happens when all stream slots are busy. The cost in normal traffic is a
lookup in an empty calendar.

**RTT latency, steady 1 post/s (p50 of end-to-end delivery, ms):**

| RTT | push | pull | hybrid |
|---|---|---|---|
| 200 | 100 | 300 | 100 |
| 600 | 300 | 900 | 300 |

Push is one way (RTT/2). Pull is notify (RTT/2) then request and answer
(RTT), so 1.5 x RTT. This is the price of the second step and it is why
the hybrid keeps sparse actors on push. In a burst with RTT 200, pull
still delivers (p50 5.7 s, 89 requests) while push drowns B (p50 18 s,
430 failed requests): RTT shifts everything by a constant, the queueing
term is unchanged.

**RTT matters for appointments.** `{:retry_at, ms}` is counted from the
moment the origin answers, but the answer needs RTT/2 to reach B and the
next request needs RTT/2 to come back, so a receiver that waits `ms` is
a full RTT late. `Puller.observe_rtt` keeps an EWMA per origin and
`finish_pull` waits `ms - rtt`. Stampede of 1000 domains, 8 slots:

| case | requests | converged |
|---|---|---|
| RTT 0 | 2048 | 1000/1000 |
| RTT 600, compensated | 2020 | 1000/1000 |
| RTT 3 s, not compensated | 15237 | 8/1000 |
| RTT 3 s, compensated | 2067 | 1000/1000 |

Lateness up to `grace_ms` (2 s) is tolerated even without the
subtraction (tested at 600 ms). Beyond that every slot is lost, so the
subtraction is what makes long-distance receivers workable.

The first decline of a domain is compensated too, because B measures
RTT from that same answer.

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
