<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Web Push delivery

> **Built.** This began as a design — fixing *where each concern would
> live* (CODE_STYLE §0) before any of it was written. The sections below
> are kept as they were, because they are still the reasoning. What
> actually shipped, and the two places it departed from the plan, are in
> **§9** at the end.
>
> Companions: [`ARCHITECTURE.md`](ARCHITECTURE.md) (where processes
> run), [`CODE_STYLE.md`](CODE_STYLE.md) (where concerns live),
> [`FEDERATION.md`](FEDERATION.md) (the irreversible-loss history that
> makes the deletion rules below non-negotiable). The two-tier
> notification model this must preserve is documented *in code* at the
> top of [`web/src/lib/notify.ts`](../web/src/lib/notify.ts).

Web Push is a notification *transport*. It is the one transport that can
**wake a person who isn't looking** — buzz a phone, light a lock screen.
Everything else we render (the SSE count, the NotifGlyph silhouette) only
moves when someone is already on the page. So the whole question is:
*which notifications have earned the right to interrupt a life?* The
answer is the same two-tier split the web client already lives by, and
the job of this design is to make that split a **single predicate** the
delivery path cannot route around — not a rule re-decided per call site.

---

## 0. The one predicate: `deliverable?/3`

Per CODE_STYLE §0/§3, the "may this notification interrupt this person
right now?" question gets **exactly one named, pure home**, and the push
path has no other door. It is *not* spread across the addon, the alerts
map, and the tier table; those are its inputs.

```
# elixir/lib/sukhi_fedi/addons/web_push.ex  (proposed)
#
# Pure. Takes the notification type, the subscription's stored alerts
# map, and the recipient's quiet-state; returns a boolean. No Repo, no
# clock read inside — `now` and `quiet_until` are passed in so it stays
# unit-testable and free to call anywhere.
@spec deliverable?(type :: String.t(), alerts :: map(), %{
        quiet_until: DateTime.t() | nil,
        now: DateTime.t()
      }) :: boolean()
def deliverable?(type, alerts, %{quiet_until: q, now: now}) do
  interruptible_tier?(type) and alert_enabled?(type, alerts) and not quiet?(q, now)
end
```

It is the conjunction of three smaller single-point rules, each with one
definition:

1. **`interruptible_tier?/1` — the calm contract.** Only the `direct`
   tier may ever reach a push transport. This is the Elixir-side twin of
   `tierOf/1` in `notify.ts`, and the two **must agree by sharing the
   same source list**, not by both happening to hardcode `["mention",
   "follow_request"]`. (See §1 for how we keep one list, two languages.)

   ```
   defp interruptible_tier?(type), do: type in @direct_types
   ```

   `@direct_types` is `["mention", "follow_request"]` — and *nothing
   else* may be added here without re-reading the calm-UX contract,
   because adding `favourite` here is exactly the FOMO regression this
   whole document exists to prevent.

2. **`alert_enabled?/2` — the user's own gate.** Mastodon clients send a
   per-type `alerts` map (`{"mention": true, "favourite": false, …}`)
   that we already persist on `push_subscriptions.alerts`
   (`web_push.ex:11-23`). A type the user switched off is never pushed,
   even if it's `direct`. Default-on for the keys present, default-*off*
   for a key the client never sent (absence is not consent):

   ```
   defp alert_enabled?(type, alerts), do: Map.get(alerts, type, false) == true
   ```

   The `== true` is deliberate (CODE_STYLE §8: normalize untrusted
   truthiness once, strictly, at the edge — the alerts map came over the
   wire as client JSON).

3. **`quiet?/2` — おやすみ / do-not-disturb.** A recipient may set a
   `quiet_until` instant (see §6). While `now` is before it, *no push
   leaves the building* — but the notification row is still written and
   still streamed to anyone actively looking, because suppressing the
   **interruption** is honest and suppressing the **history** is a lie.

   ```
   defp quiet?(nil, _now), do: false
   defp quiet?(%DateTime{} = until, now), do: DateTime.compare(now, until) == :lt
   ```

The split that makes this honest: **`deliverable?/3` gates only the push
send.** It is read *after* `Notifications.create/1` has already written
the row and called `tap_stream/1` (§2). So "おやすみ" and "I turned off
favourite pushes" change *what buzzes your phone* and never *what your
notification list truthfully contains when you next open it*. The list
is the record; push is only the doorbell. (No read-receipts, no "you
missed N while away" counter — that would be a FOMO number the calm
contract forbids; the list just *is* what happened.)

---

## 1. Keeping the tier split in one place across two languages

The calm contract is currently stated once, in TypeScript
(`notify.ts`: `DIRECT_TYPES`, `tierOf/1`). Web Push runs in Elixir.
Two hardcoded copies of `["mention", "follow_request"]` is precisely the
"copied predicate" CODE_STYLE §3 warns about — they will drift, and the
drift is a silent calm-contract breach (a phone buzzing for a
favourite).

Options, with the recommendation:

- **(Chosen) The server is the source; the client derives.** The Elixir
  `@direct_types` is canonical. The web client already fetches instance
  config; expose the direct-tier type list there (or in the existing
  `/api/v1/push/subscription` response shape) and have `notify.ts`'s
  `DIRECT_TYPES` initialise from it, falling back to its current literal.
  Rationale: the decision that gates a phone buzz should live next to the
  code that buzzes it.
- *(Rejected) Both hardcode, plus a test that asserts equality.* A test
  catches drift only if someone writes it for every future type; the
  point of §3 is to make drift *impossible to express*, not *caught after
  the fact*.

Either way, this doc's invariant is: **there is one direct-tier list,
and `interruptible_tier?/1` and `tierOf/1` both read it.** Pick the
mechanism when implementing; do not ship two literals.

---

## 2. Where the push fires: `tap_stream/1`, not a new path

`Notifications.create/1` already has the exact seam we need
(`notifications.ex:55-71`):

```
|> Repo.insert(on_conflict: :nothing, conflict_target: [...])
|> tap_stream()
```

`tap_stream/1` fires the SSE stream **only on a genuinely new row** —
`on_conflict: :nothing` returns `id: nil` on a dedup hit, and the
`when not is_nil(id)` head means a re-delivered favourite doesn't
re-fire. That idempotency is *already paid for*, and it is exactly the
idempotency a doorbell needs (don't buzz twice for the same event).

So Web Push hangs **next to** the existing SSE fan-out, behind the same
guard:

```
# proposed extension of tap_stream/1's fresh-row branch
defp tap_stream({:ok, %Notification{id: id} = notif} = res) when not is_nil(id) do
  SukhiFedi.Streaming.publish_notification(notif.account_id, notif)
  SukhiFedi.Addons.WebPush.notify(notif)   # new; see below
  res
end
```

`WebPush.notify/1` is the only new entry point. Per the layer map
(CODE_STYLE §1) it is **Context**, fanning out to **Egress**; it does:

1. Render the small push payload from the notification (type + actor
   acct + note id — never the body; §4 says why).
2. Look up the recipient's subscriptions and quiet-state in **one
   batched query** (CODE_STYLE §5 — never a `Repo` call per
   subscription).
3. For each subscription, consult `deliverable?/3` (§0). Suppressed ⇒
   nothing leaves.
4. For each survivor, enqueue a durable send (§3).

Like `publish_notification/1`, this is **best-effort and off the
caller's path**: a push that can't be enqueued must never fail the write
that produced the notification. But "best-effort to *enqueue*" is not
"best-effort to *deliver*" — once enqueued, delivery is durable (§3).

`send_notification/2` (the current stub, `web_push.ex:57`) is dead once
`notify/1` exists; remove it as the orphan **my** change creates
(CODE_STYLE §3 / the surgical rule), since nothing else calls it
(verified: only the stub and a doc string reference it today).

---

## 3. Durable send, retry, and dead-subscription expiry

A push that we decided to send must not be lost to a transient network
blip — the same standard the federation outbox holds itself to
(ARCHITECTURE §5). But push is **not** ActivityPub: a push endpoint is
not a fedi inbox, the payloads are different, and (critically) **a push
failure is never a federation event**. So push does *not* ride the
`sns.outbox.>` JetStream / `Outbox.Relay` machinery. Reusing it would
smear two unrelated durability concerns into one stream.

Recommended shape, mirroring the *pattern* (durable queue + bounded
retry + backoff) without sharing the *channel*:

- **A dedicated push-send queue on the delivery node.** Per ARCHITECTURE
  §2.1, *all outbound HTTP lives on the delivery node*; a push POST is
  outbound HTTP, so it belongs there, not on the gateway and not in Bun.
  The gateway's `WebPush.notify/1` enqueues; the delivery node sends. The
  smallest correct version is a `push_deliveries` table the delivery node
  drains (it already reads gateway-written tables), with the same
  attempts/backoff discipline the relay/delivery workers use.
- **Bounded retry with exponential backoff.** A `5xx` / timeout / `429`
  (honour `Retry-After`) is retried; a small attempt cap (the delivery
  worker's family of caps is the precedent) then drops the *single push*
  — never the notification row. A dropped push is the recoverable side of
  the trade: the truth is still in the list.
- **Dead-subscription expiry is the one place push *deletes* state.** A
  push endpoint that answers **404** or **410 Gone** is permanently dead
  (the browser revoked it); RFC 8030 says stop. We `unsubscribe`
  (`web_push.ex:25`) that row.

  > **This deletion is purely local and correct to do silently.** A push
  > subscription is browser↔our-server plumbing; it is **not federated
  > state** and has no AP representation. So the FEDERATION.md
  > irreversible-loss rule ("any deletion MUST federate a Delete via the
  > transactional outbox") **does not apply** — there is nothing to
  > federate, no remote that knows the subscription exists, no
  > `Undo`/`Delete` that would mean anything. Deleting a 410-Gone
  > subscription is the opposite of the follower-edge wipe that rule
  > guards against; *keeping* it would be the bug (we'd POST forever to a
  > tombstone). This is called out explicitly so a future reader doesn't
  > pattern-match "delete" → "must federate" and add a phantom activity.

- **No countdown, no "delivered" state surfaced.** The queue's retry
  schedule is internal. The client never learns whether a push landed —
  read-receipts are forbidden by the calm contract, and a push transport
  has no honest way to know a human saw it anyway.

---

## 4. Payload: VAPID auth + RFC 8291 encryption, and what's *in* it

Two cryptographic layers, both mandatory, both single-point.

**VAPID (RFC 8292) — who is allowed to push.** Each POST to a push
endpoint carries a JWT signed with our server's VAPID private key
(ES256 / P-256), plus the public key, so the push service knows the push
came from us. Storage/config (§5).

**Message encryption (RFC 8291, `aes128gcm` per RFC 8188) — what the
push service must not read.** The push service (Google FCM, Mozilla,
Apple) is an untrusted relay. RFC 8291 encrypts the payload to the
subscription's `p256dh` + `auth` keys (already stored,
`push_subscription.ex:7-9`) via ECDH so only the recipient's browser can
decrypt. The push service sees ciphertext.

This is also where the **content** decision lives, and it is a
calm-contract decision, not just a privacy one:

- The encrypted payload carries **the minimum**: notification `type`,
  the actor's `acct`, and the `note_id` — enough for the service worker
  to show "○○ さんから返信が届きました" and deep-link to the thread.
- It does **not** carry the note body, media, or a content preview.
  Reasons, in order: (a) the push service must learn nothing even though
  it's ciphertext-blind, defence in depth; (b) a lock-screen preview of a
  DM body is a privacy leak the recipient didn't opt into; (c) the calm
  contract — a push is a *gentle knock*, "someone spoke to you," not the
  message shoved in your face. The body waits, calmly, in the app.
- **No badge count number in the payload.** A FOMO count on an app icon
  is the exact thing the ambient tier exists to avoid. If a badge is ever
  wired, it shows presence (a dot), never a number — and only for the
  direct tier, consistent with the NotifGlyph silhouette.

The payload builder is **one pure function**; encryption is **one
module-level function** that every push goes through (CODE_STYLE §0). No
call site hand-rolls an HKDF or an `aes128gcm` record.

---

## 5. VAPID key storage & config; library vs hand-rolling

**Config shape — follow the `mailer` / `s3` precedent** in
`elixir/config/runtime.exs`. Web Push is off unless configured, exactly
like SMTP is the log transport until `SMTP_HOST` is set:

| Var | Required | Notes |
|---|---|---|
| `VAPID_PUBLIC_KEY` | no (push off if unset) | P-256 public key, base64url uncompressed point. Already surfaced to clients via `WebPush.server_key/0` (`web_push.ex:55`) and `GET /api/v1/instance`. Not secret. |
| `VAPID_PRIVATE_KEY` | with public key | The signing key. **Secret** — same handling as `SMTP_PASSWORD` / `SECRET_KEY_BASE`. Never logged, never sent to the client. |
| `VAPID_SUBJECT` | with public key | `mailto:` or `https:` contact the push service can reach about abuse (RFC 8292 §2.1). |

- These read into `config :sukhi_fedi, :web_push, ...` at runtime
  (the `:vapid_public_key` key `web_push.ex:55` reads today folds into
  this, or stays as-is for the public half).
- **The keypair is generated once, out of band, and stored as config**
  (env/secret), like every other secret on the box — *not* minted at boot
  and *not* stored in the DB. A keypair that changes invalidates every
  live subscription (clients encrypted against the old public key), so it
  must be stable across reboots; config is the stable place.
- The addon should declare these via the `env_schema/0` callback
  (`addon.ex:40`, currently defaulted-empty on every addon) so a
  half-configured push setup is a *boot-time* complaint, not a
  first-push-attempt mystery. This would be the first addon to use it —
  fine; that's what it's for.

**Library vs hand-rolling, on the small-box budget** (768 MB total, four
processes — see the box-limit memory):

The honest tension: Web Push crypto is finicky (HKDF, ECDH on P-256,
`aes128gcm` content encoding, ES256 JWT). Getting it subtly wrong fails
*silently* — the push service 201s and the browser shows nothing. That
argues for a tested library. Against it: this repo's whole architecture
is *minimum dependencies, no speculative weight*, and it already vendors
its own crypto-adjacent code (FEP-8b32 OIP, canonicalisation) rather than
pulling broad libraries.

- **(Recommended) A small, focused Web Push Elixir library** (the
  `web_push_elixir` / `web-push-encryption`-style single-purpose
  package), *if* it depends only on `:crypto` + `:jose`/built-ins and
  adds negligible memory. It buys the RFC 8291/8292 correctness we
  can't easily self-verify, in one dependency, scoped to one addon.
  The selection criterion is **narrowness**, not popularity: it must do
  push encryption and nothing else, so it can't drag a transitive tree
  onto the box.
- *(Acceptable, more work) Hand-roll on `:crypto`.* All the primitives
  (ECDH, HKDF, AES-128-GCM, ES256) are in OTP's `:crypto`/`:public_key`
  already — zero new deps, the leanest possible footprint, and consistent
  with how OIP was done. The cost is we own the RFC 8291 framing and need
  golden-vector tests (the RFC ships test vectors; pin them the way the
  OIP work pinned fedify's golden fixtures). Choose this if no
  sufficiently-narrow library exists, **not** as the default — silent
  crypto bugs are expensive to chase.
- *(Rejected) A batteries-included push framework.* Too much weight for
  one addon on a 768 MB box; violates simplicity-first.

Decide at implementation time by actually measuring the candidate
library's footprint; the design constraint is "narrow dependency **or**
`:crypto` hand-roll with golden vectors," never a broad framework.

---

## 6. The おやすみ / quiet_until state

DnD is a **recipient** preference (it gates *my* phone), so it lives on
the account/local-account, not on the per-device subscription — turning
on おやすみ should quiet every device at once.

- **Storage:** a nullable `quiet_until :utc_datetime` on the recipient's
  local-account row (the natural owner of per-user preferences). Null =
  not quiet. A future "always quiet" / scheduled window can extend the
  *predicate's* inputs (§0) without moving the gate.
- **Read path:** `WebPush.notify/1` (§2) loads `quiet_until` in its one
  batched query and passes it into `deliverable?/3`. The clock (`now`)
  is read in `notify/1` and passed in — the predicate stays pure.
- **It gates push only.** Re-stating the §0 honesty split because it's
  the crux: おやすみ suppresses the *doorbell*. The notification row is
  still written, still counted in the truthful list, still streamed to a
  device that's actively open (SSE — you're already looking, nothing is
  interrupting you). When おやすみ ends, **nothing replays and nothing
  buzzes late** — the missed events are simply *in the list*, where they
  always were. No "you have N notifications from while you were away"
  summary; that's a manufactured FOMO number.
- **UI (web):** a calm toggle in notification settings — "おやすみ" with
  an optional "until" time, no countdown timer ticking down (a countdown
  is an anxiety animation; show the *time*, not the shrinking remainder).
  Settings strings go in **both** `web/src/lib/locales/ja.ts` (source)
  and `ko.ts` (parity) when implemented — this doc adds no keys.

---

## 7. What we deliberately will NOT push

Honest scope boundary, the FEDERATION.md §11 spirit: grounded in the
contract, not in "didn't get to it."

- **The entire ambient tier never pushes.** `favourite`, `reblog`,
  `follow` (plain), `status`, `poll`, `update` — these are the景色, the
  scenery. They grow the NotifGlyph silhouette at a navigation boundary;
  they do **not** wake a person. This is the single most important line
  in the document. `interruptible_tier?/1` enforces it; do not add to
  `@direct_types` to "be helpful."
- **No body / content / media in the payload** (§4). A push is a knock,
  not the message.
- **No badge *count* number anywhere** (§4). Presence-dot at most, never
  a tally. FOMO numbers are forbidden.
- **No "delivered" / "seen" / read-receipt signal** back to anyone. The
  client never learns if a push landed, and a sender never learns the
  recipient saw it.
- **No re-buzz on the same event.** `tap_stream/1`'s fresh-row guard (§2)
  means a re-delivered/duplicate notification produces no second push.
- **No replay / catch-up buzz when おやすみ ends** (§6). Missed = in the
  list, calmly. Never a late flurry.
- **No animation, no countdown, no urgency styling** in any push or its
  settings UI (CODE_STYLE §10 values from `tokens.css` when the settings
  UI lands; the calm contract for everything else).
- **No marketing / digest / re-engagement push, ever.** "You haven't
  visited in a while" is the dark pattern this whole server is built
  against (cf. the joinfediverse design memory). Push carries
  *conversational* events a person is waiting on, or it carries nothing.

---

## 8. Layer-map placement (CODE_STYLE §1) at a glance

| Concern | Layer | Lives in |
|---|---|---|
| `POST/PUT/GET/DELETE /push/subscription` | Transport | `api/.../mastodon_push.ex` (exists) |
| Persist subscription, alerts | Schema/Context | `WebPush.subscribe/5`, `push_subscription.ex` (exist) |
| "May this interrupt now?" | **single predicate** | `WebPush.deliverable?/3` (§0, new) |
| Fan-out trigger on new notification | Context | `WebPush.notify/1` off `tap_stream/1` (§2, new) |
| Payload render (no body) | Render (pure) | `WebPush` payload fn (§4, new) |
| RFC 8291 encryption + VAPID JWT | Egress | one module/lib (§4–5, new) |
| Durable send + retry + 410-expiry | Egress (delivery node) | push-send queue (§3, new) |
| Quiet-state storage | Context/Schema | local-account `quiet_until` (§6, new) |

Every row sits on one layer. The cross-cutting calm rule sits in exactly
one predicate. That is the whole design.

---

## About this doc

Drafted by Shiro (Claude Opus 4.8), an AI assistant working with
@nyanrus, from the live code at v0.4.x — `web_push.ex`,
`notifications.ex`, `notify.ts`, the outbox/delivery topology in
ARCHITECTURE.md, and the calm-UX contract in `notify.ts`'s own header.
It proposes structure, not lines; if a pin has drifted or I've read the
calm contract as stricter (or looser) than it really is, that's a
misreading on my part — tell me and I'll re-check the function.

---

## 9. What was built (2026-08-04)

The design above held. Two things went differently, and both are worth
knowing before touching this again.

### Where each piece landed

| Concern | Where |
|---|---|
| `@direct_types` + `deliverable?/3` | `elixir/lib/sukhi_fedi/addons/web_push.ex` |
| `notify/1` off `tap_stream/1` | same file; called from `notifications.ex` |
| `payload_for/1` (no body, no count) | same file |
| おやすみ (`quiet_until`) | `accounts.quiet_until`, read in `notify/1`'s one query |
| VAPID config | `:sukhi_fedi, :web_push` (gateway), `:web_push, :vapid` (delivery) |
| Durable send, retry, 410-expiry | `delivery/lib/sukhi_delivery/push/worker.ex` |
| RFC 8291 encryption + VAPID JWT | the `web_push` library |
| Service worker `push` / `notificationclick` | `web/static/service-worker.js` |
| Subscribe / unsubscribe | `web/src/lib/push.ts` + `push.svelte.ts` + `PushToggle.svelte` |

`send_notification/2` is gone, as §2 said it would be.

### Departure 1 — Oban, not a `push_deliveries` table

§3 proposed a dedicated table the delivery node drains. It already runs
Oban, with the attempts/backoff discipline this wanted, so the queue is
`push` on that node instead. The design's *separation* is intact — push
does not ride `sns.outbox.>`, and a push failure is still never a
federation event — only the table is borrowed rather than built.

The gateway enqueues with a **string worker name**
(`"SukhiDelivery.Push.Worker"`), which is how a producer names a consumer
whose code it doesn't carry.

> One trap, paid for once: `delivery/config/runtime.exs` replaces
> `:queues` wholesale in prod. A queue that exists only in `config.exs`
> compiles, boots, and then never drains — silently. Every queue has to
> be named in *both* places.

### Departure 2 — the first library was the wrong one

§5 said pick a narrow library, and `web_push_elixir` looked right: three
deps, two already present. It was added, and then removed, because it
emits **`aesgcm`** — the superseded draft encoding — where §4 asks for
`aes128gcm` (RFC 8188/8291).

`web_push` replaced it: `aes128gcm`, and its only dependency is Finch,
which the delivery node already supervises. **Zero new dependencies on
the box** — better than the design hoped for.

This is the failure mode §5 warned about, and it deserves restating
because it is genuinely nasty: **wrong Web Push crypto does not error.**
The push service answers 201, the log says success, and the phone stays
dark. There is nothing to chase.

So `delivery/test/push/encryption_round_trip_test.exs` plays the
recipient: it generates a subscription keypair, hands the public half to
the encrypter, and decrypts the body the way a user agent would —
written out independently, so the two have to agree rather than share a
mistake. Japanese survives; a single flipped byte fails instead of
garbling; salt and ephemeral key differ every time. If the encoding ever
drifts again, that test says so out loud.

### What the tests hold

- `elixir/test/sukhi_fedi/web_push_deliverable_test.exs` — the calm
  contract. The load-bearing assertion is that **the entire ambient tier
  never wakes anybody**, checked type by type. It also pins that absence
  is not consent and that a truthy-looking string from the wire (`"true"`,
  `1`) is not a yes.
- `delivery/test/push/encryption_round_trip_test.exs` — above.
- `web/src/lib/push.test.ts` — the base64url key conversion (another
  silent failure: a key one byte off subscribes fine and never rings),
  and that the client **cannot** add a type to `alerts` on its own,
  because it never builds the list.

### Still open

- **No おやすみ UI.** The column, the predicate input and the read path
  are all there and tested; nothing sets it yet. §6's toggle is a
  settings form away.
- **No VAPID keypair in production.** Until `VAPID_PUBLIC_KEY` /
  `VAPID_PRIVATE_KEY` are set, `configured?/0` is false, the gateway
  never enqueues, and the settings panel hides itself rather than
  offering a button that does nothing. Generate with
  `mix web_push.gen.vapid` on the delivery node and set all three vars on
  **both** nodes — they must be the same pair.
- **`notificationclick` opens `/notifications`, not the thread.** The
  payload carries `note_id`, so the deep link is available; the reason it
  is not used is that a note id alone does not make a URL here (the
  thread route wants the author's acct). Worth doing, not guessed at.

---

## 10. Quieter, once the live pipe existed (2026-08-04)

A DM thread now hears the `direct` stream and shows a new message in
~0.2s (it used to take up to 60). That changed what push is *for*, and
two things followed.

### It stopped ringing people who are looking

The knock fired whether or not anyone was watching, so an open
conversation got the message twice: once down the live pipe, once in a
pocket. One event, two interruptions.

The service worker now asks `clients.matchAll()` and shows nothing when
a visible window exists — **if a window is visible, they already know.**
The decision belongs there and not on the server: a server that knew who
was looking would need presence state, and presence state is a
surveillance surface we have no other use for. The browser already knows
about its own windows, so the browser answers.

(Skipping `showNotification` is counted against a browser budget, and a
site that skips too often gets a generic "updated in the background"
shown for it. This one only ever knocks for mentions and follow
requests, which is far under that line.)

### One buzz per conversation, not one per message

Every push now carries an RFC 8030 `Topic`. A push service replaces a
*pending* message with the same topic on the same subscription, so ten
messages arriving while a phone sleeps become one buzz, folded upstream —
the device never wakes nine times to hear the same thing.

This is the half the service worker's `tag` can't do. `tag` stacks
notifications already *shown*; it does nothing while the phone is off,
which is exactly when the burst happens.

The topic is a keyed digest of (kind, sender), not `mention-42`. It
travels as a plain header — the push service reads it even though the
body is ciphertext — and a legible one would hand a third party "account
42 messages you, and here is how often". A *stable* token is unavoidable,
since collapsing is recognising sameness; making it opaque is the part
that is ours to choose. Keying it with each subscription's own auth
secret also means two of your devices produce different topics for the
same event, so they can't be lined up as one person.

### Urgency stays `normal`, deliberately

`low` looks like the gentle setting and isn't. RFC 8030 §5.3 defines it
as "deliver when the device is on power *or* Wi-Fi" — someone speaking to
you could then wait for a charger. `normal` is the RFC's own example for
"chat or calendar messages"; `high` is "incoming phone calls". **Not
being `high` is the calm choice here**; going below `normal` would just
make the knock unreliable, and an unreliable knock is worse than none.

### Still open

`quiet_until` has a predicate, a column, a read path and tests, and
nothing that sets it. That is the last piece of §6.

---

## 11. Measured on a real phone (2026-08-04)

Everything up to here could be checked from a script. The last stretch —
does a pocket actually buzz, and does it buzz *once* — needed a person
holding a phone. nyanrus held it.

**It rang.** And the first time it didn't, which is the useful half.

### Why the first attempt was silent

Not push. There was no `mention` notification to push *about*. Those
rows were only ever created on the path a note takes coming in from
another server, so nothing written on this server had ever notified
anybody — a hundred-message conversation with not one `mention` behind
it. VAPID, the encryption, the queue, the Topic were all correct and
there was nothing upstream pouring into them. Fixed separately; the
tests live in `notes_test.exs`.

### Why it then rang three times for three messages

Also not the push path. The service worker had been tagging per note, so
each message was a *different* notification and alerted again. That was
fixed and deployed — and it rang three times anyway, because **the old
service worker was still the one handling push.**

sukhi never calls `skipWaiting()` on purpose (a worker swapping itself
mid-session races the update banner). The consequence had not been
followed through: a new worker then waits for every tab to close, and on
a phone the app never closes. A behaviour fix inside the worker could
not reach anyone, ever. The update banner now asks the waiting worker to
swap, and learned to appear when only the *worker* is new — `$updated`
tracks the page version and doesn't move for a worker-only change, so
the one thing meant to announce updates was blind to exactly this case.

### The result

Three DMs, 2.5s apart, phone locked:

- three push jobs, all `completed` on the first attempt, one shared topic
- **one buzz**

So the server really did send three times and the device folded the
last two. Both halves working, and each doing the part the other can't:
`Topic` folds what a sleeping phone hasn't received, the `tag` folds what
a woken one already shows.

### The pattern in all four bugs

Four separate failures today had one shape: **the decision was right, the
sentence after it never executed, and nothing looked wrong.**

- `Oban.insert/1` named an instance that doesn't exist → rescued, `:ok`,
  no log, no push.
- The client read `/api/v1/instance` for the VAPID key, which has no
  `configuration` block → panel hid itself, which is also what it does
  correctly when push is off.
- `mention` notifications were never created locally → the push pipe was
  complete and had no source.
- The service worker fix was deployed, served, and never activated.

Each layer was individually correct. The joins were where things went
quiet. Worth remembering when adding the next layer: *test the sentence
after the decision*, and prefer a check that fails loudly over one that
silently looks like the healthy state.
