# Pull Federation

> Pull Federation is this project's own protocol, not a FEP. FEP-844e is only how a server announces it. Capability id (`implements.href`) for this document:
> `https://github.com/sukhi-social/sukhi-fedi/blob/main/docs/PULL_FEDERATION.md`

A server that implements this keeps its normal inbox. For `Create(Note)`
only, an origin can tell a follower's server "I have something new" with
one small signed `POST`, and the follower's server then fetches what it
wants, when it wants, in batches. One notification replaces one POST per
post per follower; a busy origin stops being a fan-out machine.

It is opt-in on both sides and only ever used between two servers that
both declared the capability. Anyone else gets exactly what they got
before: a push to their inbox.

## 1. Discovery (FEP-844e)

An actor of a server that implements this carries

```json
"generator": {
  "type": "Application",
  "implements": [{
    "href": "https://github.com/sukhi-social/sukhi-fedi/blob/main/docs/PULL_FEDERATION.md",
    "name": "Pull Federation (notify, then pull)"
  }]
}
```

with `https://w3id.org/fep/844e` in the actor's `@context`, and says where
to send and pull in the actor's `endpoints`, next to `sharedInbox`:

```json
"endpoints": {
  "sharedInbox": "https://origin.example/inbox",
  "pullNotify": "https://origin.example/pull/v1/notify",
  "pullStream": "https://origin.example/pull/v1/stream"
}
```

No path is assumed. A peer is capable only if it names the capability
**and** both URLs; each URL must be `https`, on the same host as the
actor's `id` (so nobody can aim our traffic at a third party), and at
most 512 bytes. The paths above are just where this implementation
happens to serve them. The URLs are stored with the host in
`peer_capabilities` (`pull_notify`, `pull_stream`) and read through
`PeerCapabilities.endpoints/2`, the one place a peer's endpoint is looked
up.

- We learn it from every remote actor we already fetch (no extra
  request). It is recorded per host in `peer_capabilities`
  (`SukhiShared.PeerCapabilities`) and is fresh for **14 days**; after
  that the host is treated as not capable until we see it again.
- Reading is tolerant: at most 64 entries, each `href` at most 512
  bytes, anything malformed means "not capable".
- `PULL_FEDERATION=off` removes `generator` from our actors and answers
  both endpoints below with 404. Peers drop us after their next actor
  fetch; until then they get a 404, which makes them fall back (§5).

## 2. Wire format

Everything is HTTP Signatures, signed by the origin's instance or an
actor key (the same verification as the inbox, `SignedRequest.verify`).

**Notify** — origin → follower's server

```
POST <the follower host's pullNotify>
{"type":"PullNotification","origin":"origin.example",
 "heads":{"https://origin.example/users/a": 1234}}
```

`heads` maps each actor with news to its newest sequence number. The
signer's host must equal `origin` (else 403). Replies: `202` accepted,
`404` we do not do this, or we have no endpoint for that origin (sender falls back to push), `429`/`503` with
`Retry-After` (sender snoozes). A host blocked by moderation
(`instance_policy == :reject`) gets 403 and no further work.

**Pull** — follower's server → origin

```
GET <the origin's pullStream>?c[]=<seq>@<actor_uri>&c[]=…
```

Up to 64 cursors. The reply is a `PullPage`: per actor, up to 100
activities after the cursor, in order, plus the new cursor. The first
contact (cursor `0`) gets the newest 20 only. A cursor older than the
actor's `pruned_through` gets `resync` for that actor: the puller
re-bases on the newest and does not walk history. A *gap* (an activity
withdrawn because the post was deleted) is not a resync; the cursor
just moves past it. `429`/`503` with `Retry-After` means busy, try
later.

The origin serves at most `PULL_MAX_STREAMS` (default 16) streams at
once (`PullFederation.Gate`, one atomic counter); beyond that, `429`
with `Retry-After` of 2 to 4 seconds. The notify endpoint has a floor of
5 requests per second per origin.

## 3. Roles of the two nodes

Following `ARCHITECTURE.md`: the **gateway** is the only inbound HTTP
and the only writer of the core schema; the **delivery node** does
outbound HTTP and writes narrow projections.

| | Gateway (`elixir/`) | Delivery (`delivery/`) |
|---|---|---|
| Origin side | `GET /pull/v1/stream` (`Serve`, `Gate`) | `Route.split` (push vs. notify per follower host), `Log.append`, `NotifyWorker`, `Fallback`, `PruneWorker` |
| Follower side | `POST /pull/v1/notify` (`Notify`), `Puller`, `Pull` | – |
| Applying | every pulled item goes through `AP.Ingest.run`, the same admission path as the inbox | – |
| Metrics | `PullFederation.Stats`, `/admin/pull_federation` | `SukhiShared.PullStats` flusher |

Tables (migration `20261024000001_create_pull_federation`):
`peer_capabilities`, `pull_heads`, `pull_log`, `pull_peers`
(breaker), `pull_pending`, `pull_cursors`, `pull_hosts`, `pull_stats`,
`pull_peer_stats`.

## 4. What goes by pull, and what never does

Only `note.created` to followers of hosts that declared the capability.
Everything else is pushed exactly as before:

- **Delete is always pushed**, to everyone, in parallel, with backoff
  retries. It is never turned into a notification.
- Follow, Accept, Undo, Like, Announce, Update, Move, DMs, and anything
  addressed to a specific inbox are pushed.
- A host that is also a recipient of the push (for example a mention)
  gets the push and is not notified twice.

## 5. Failure and fallback

- The origin keeps a per-host breaker (`pull_peers`): after **5
  consecutive notify failures** the host is pushed to instead; one
  half-open try after **30 minutes**.
- `NotifyWorker` (queue `federation`, up to 6 attempts, one scheduled
  job per host with a 1 s quiet window so a burst is one notification)
  snoozes on 429, and falls back to push (`Fallback.push`) on 404, 410,
  501, on a blocked host, or on its last attempt. Nothing is dropped:
  `Log.append` is idempotent on `activity_id`, and fallback pushes the
  same activity the log holds.
- The puller backs off per origin with full jitter, capped at one hour,
  runs at most `PULL_MAX_CONCURRENT` (default 4) pulls, and advances its
  cursor past items it refuses (moderation, bad proof), so a bad item
  cannot wedge a feed.
- `Log.prune` (hourly) keeps 14 days and 10,000 rows per actor.

## 6. Metrics

`SukhiShared.PullStats` counts in ETS and flushes hourly rows to
`pull_stats` and per-host rows to `pull_peer_stats`; the admin page
`/admin/pull_federation` (also `.json`) shows POSTs avoided, notify
sent/failed, fallbacks, pulls ok/failed/declined, publish-to-apply lag,
the busiest peers and their breaker state. The dashboard shows
"POSTs avoided (24 h)". Rows older than the metrics retention are
pruned by `Metrics.prune`.

## 7. Replacing the notification

The "I have news" step is a stopgap. A FEP for server-status
broadcast ("I am up, you may send again") is being written with
others; when it is published, the notification is **replaced** by it,
not switched with a flag. Pull itself (§2 Pull, the log, the cursors)
stays. The notification lives in exactly these places, and nowhere else:

| Part | Place |
|---|---|
| Sending (origin) | `delivery/.../pull_federation/notifier.ex`, `notify_worker.ex` (and the `heads` query in it) |
| Receiving (follower) | `elixir/.../pull_federation/notify.ex`, `POST /pull/v1/notify` in the controller and router |
| Its counters | `notify_sent`, `notify_failed`, `notify_received`, `notify_dropped` |

Everything downstream is independent of how the follower learned there
is news: `pull_pending` (host and actors to pull), `Puller`, `Serve`,
`Fallback`. The replacement therefore only has to put hosts into
`pull_pending` (receiving side) and decide when to tell a host
(sending side); the capability href moves to the new FEP's.

## 8. Honest limits

- **Delete racing a pulled Create.** A Delete is pushed immediately; a
  follower that has been notified but has not pulled yet may later pull
  the Create. We retract the log row when the note is deleted, so a
  pull after that does not return it; but a Create already in flight
  (pulled, not yet applied) can land after the Delete and resurrect the
  post, because production keeps no tombstones. This window is small
  and is not closed.
- Appointments and the calendar, the second private index, and
  streaming exist only in the `prototypes/pull_federation/` prototype.
  They are not ported.
- Capability knowledge is only as fresh as the last actor fetch (14
  days); a peer that stopped supporting it answers 404 and is pushed to.
- Both sides must implement this document. There is no negotiation of
  options: no capability, no pull.
