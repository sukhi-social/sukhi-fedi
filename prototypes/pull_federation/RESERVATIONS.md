# Pull reservations: design

Status: prototype. Code: `lib/pull_federation/calendar.ex` (the rules),
`lib/pull_federation/origin.ex` (`request_stream/4`, the only caller),
`lib/pull_federation/puller.ex` (`finish_pull/5`, the receiver's side).
Tests: `test/calendar_test.exs`, `test/flood_test.exs`.

## 1. The problem

A pull stream is the expensive request: it reads the database and holds a
connection. The origin therefore admits only `max_streams` at a time.
When a thousand receivers want one at once (a popular post, an outage
ending, a restart), the others must be told to come back later. If the
origin just says "busy", every receiver has to guess when. That fails in
two ways, both measured in README part 5:

- **Guessing wastes the origin's capacity and the receivers' requests.**
  Exponential backoff with jitter, 1,000 receivers: 4.4 requests each and
  the last one is served after 220 s, while stream slots sit idle between
  retries.
- **Without jitter it never converges.** 48 of 1,000 receivers were served
  after 300 s: they retry in the same wave.

The origin knows its own capacity and its own queue. So it should say
*when*.

## 2. The idea

A calendar of appointments, one every `slot_ms`. A declined receiver is
given the next free one and told how long to wait. It comes back at that
time and is served. Two requests per receiver in the common case.

## 3. Wire protocol (proposal)

The receiver's pull request is HTTP-signed. Only after the signature
identifies a domain the origin has a follower from does anything below
happen; an unsigned or unknown caller never touches the calendar (it gets
`403`, `:unknown_domain` in the prototype).

| Origin says | HTTP | Meaning | Receiver does |
| --- | --- | --- | --- |
| stream | `200` (NDJSON) | admitted | process, then `finish_pull` |
| appointment | `503`, `Pull-Retry-In: <ms>`, `Retry-After: <s, rounded up>` | your slot is exactly `ms` from now | wait `ms` (+ at most 20 ms jitter), then pull again; no backoff growth |
| shed | `503`, `Retry-After: <s>` only | nothing promised (the calendar is full to the horizon) | wait at least that long plus jitter, then backoff as usual |
| unknown | `403` | no follow from this domain | stop asking; rely on push / outbox |
| too soon | `503` with `Pull-Retry-In` | you came back before your time (or inside `min_pull_gap_ms`) | wait the remaining time; **no** new promise is made |

Times are **relative** and measured from receipt of the response on the
receiver's own clock. No clocks are compared, so skew cannot matter;
network latency shifts an arrival by milliseconds, which `grace_ms`
absorbs. `Retry-After` is there for generic clients that do not know the
extension; it has one-second resolution, which is why `Pull-Retry-In`
exists.

## 4. State (all bounded)

| Field | Size | Purpose |
| --- | --- | --- |
| `next_slot` | one integer | time of the next free appointment |
| `entries` | `domain => at`, at most one per known domain | live promises |
| `ewma_stream_ms` | one float | observed stream time |
| `last_pull` (Origin) | one integer per known domain | `min_pull_gap_ms` |

"Known domain" means a domain that has a follow here, so memory is bounded
by the follow table, not by the attacker. Lapsed entries are swept lazily
(`sweep/2`) and forfeited on the next contact.

## 5. Rules

Each is enforced in `Calendar` and tested.

1. **One promise per domain.** Asking again while holding one returns the
   time left; no second promise (test: "a full house hands out
   appointments; coming early costs nothing").
2. **Early is refused, on time is served, late within `grace_ms` is served,
   later forfeits.** A forfeited domain is a fresh arrival.
3. **Beyond `horizon_ms` nothing is promised** and the receiver is told to
   try after `horizon_ms`. The book cannot grow without bound (test:
   "the horizon sheds").
4. **Spacing with headroom.** `slot_ms = ewma_stream_ms / (slots *
   utilization)`, utilization 0.8. See section 7.
5. **No cutting in line.** While anything is promised ahead
   (`pending?/2`), a domain with no promise books like everyone else, even
   if a stream slot happens to be free (test: "nobody walks in ahead of a
   promise").
6. **A holder who finds every slot taken keeps its promise**, moved one
   slot ahead of now (`postpone/3`). The book is not touched.
7. **An idle book starts from now**, not from a stale pointer.
8. **A holder is never nagged.** Notifications to a domain with a live
   promise are suppressed (it will pull anyway), and an admitted pull
   clears the domain's pending notification (the stream already contains
   it).

Property test: over 5,000 random requests and closes, `active_streams`
never exceeds `max_streams`, always equals the number of open streams, the
book never has more entries than known domains, and `next_slot` never goes
backwards.

## 6. Failure modes

- **Origin restarts.** The calendar is lost. Receivers arrive at their
  old times with no entry, are treated as fresh arrivals, and are either
  served (if the house is empty) or booked again. Cost: one extra request
  each. Nothing is lost, because the log and cursors are elsewhere.
- **Receiver never comes back.** The slot is wasted; the entry lapses after
  `grace_ms` and is swept. Capacity wasted is at most one slot per missed
  appointment.
- **Response lost in transit.** The receiver retries by its own rules
  (generic backoff); the origin sees an early or on-time arrival and
  answers consistently, because the promise is per domain, not per request.
- **Receiver ignores the promise and hammers.** The calendar does not
  grow (rule 1), the database is not touched, and a decline is a verify and
  a send. It is still 311,797 requests in the README part 5 test. The
  protocol cannot fix that; it is an edge problem (per-IP limit, `429`
  before the signature check). What the calendar guarantees is that
  hammering does not displace anyone's appointment.
- **Stream longer than expected.** `ewma_stream_ms` rises and `slot_ms`
  follows (test: "the slot follows the observed stream time"). A sudden
  slowdown is absorbed by the 20% headroom first.
- **Clocks.** Relative times only (section 3).

## 7. What went wrong on the way (kept so it is not repeated)

1. **First version: one counter, no grace, no notion of "walk-in".**
   Converged in 2.1 requests per domain, but a domain that lost its slot
   was re-booked at the end of the calendar, a promise could never lapse,
   and there was no rule against taking a free slot ahead of promised
   domains.
2. **Second version: slot spacing equal to service time (utilization
   100%).** One late arrival found the house full and was postponed one
   slot, which collided with the next holder, who was postponed in turn:
   the same few receivers cycled every slot while the queue never drained.
   13 requests per domain (13,195 for 1,000) instead of 2. The cause is
   queueing theory's usual one: utilization 1.0 has no slack. Fixed by the
   0.8 factor; the price is 25% longer to serve everyone (63 s instead of
   50 s for 1,000 domains).
3. **Retry jitter proportional to the wait** put arrivals randomly across a
   window wider than a slot. Now at most 20 ms.

## 8. Parameters

| Name | Default | Notes |
| --- | --- | --- |
| `max_streams` (slots) | 8 | per origin, capacity of the database path |
| `utilization` | 0.8 | below 1.0 or the queue never drains |
| `slot_ms` | `ewma / (slots * 0.8)`, starts at 50 | adapts to measured stream time |
| `grace_ms` | 2,000 | how late a holder may arrive |
| `horizon_ms` | 300,000 | how far ahead anything is promised |
| `min_pull_gap_ms` | 0 (off) | useful when appointments are off |

None was tuned beyond the experiments in the README; real values come from
measuring streams on a running instance.

## 9. Not covered

Priorities (a domain with many followers served first); fairness across
origins on the receiver side; promising a slot to a *notification* (so the
pull is booked before the receiver asks); persisting the calendar.
