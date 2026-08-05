# Code style: separation

> How code in this repo is shaped so that **security and performance
> follow from structure**, not from per-PR vigilance. Companion to
> [`ARCHITECTURE.md`](ARCHITECTURE.md), which fixes *where processes
> run*; this file fixes *where concerns live inside the code*.

## 0. The rule

**Every security or performance property lives in exactly one place,
and structure routes all paths through it.**

- Security: check **once, at the boundary** — then the inside may
  trust. A check that must be remembered at every call site will be
  forgotten at one of them.
- Performance: pay **once, per batch** — sanitize on write so reads
  serve as-is; filter in the SQL `WHERE` so rows never surface;
  count in one grouped query so lists never loop.

The two are the same rule. A concern that is *separated into one
place* is both auditable (security) and payable-once (performance).
A concern that is *smeared across call sites* is neither.

## 1. The layer map

Request → response crosses these layers, in order, and each layer
does **only** its own job:

| Layer | Lives in | Owns | Must not |
| --- | --- | --- | --- |
| Transport | `api/capabilities/`, `elixir/web/` controllers | HTTP parsing, status codes, content-type, pagination params | business rules, queries, visibility |
| Verify | inbox signature verify, `Router` bearer auth | *who is speaking* | parsing the payload it guards |
| Normalize | `bun/handlers/inbox.ts` parsers, `decode_*_attrs` | raw bytes → typed instruction/attrs | DB access, side effects |
| Context | `elixir/lib/sukhi_fedi/*.ex` (Notes, Social, Timelines, …) | business rules, authorization, queries | HTTP shapes, JSON rendering |
| Schema | `schema/*.ex` changesets | field validation, coercion, **sanitization** | queries, network |
| Egress | `UrlGuard`, delivery worker, fedify sign | *who we speak to* | building the payload it sends |
| Render | `api/views/` | DB structs (+ prefetched maps) → JSON | queries, per-item IO |

A function that visibly spans three rows of this table is the smell
to refactor. One row, one function (or one short pipeline of them).

## 2. Ingress: verify → classify → execute

The inbox is the model for any untrusted entry point
(`elixir/lib/sukhi_fedi/web/inbox_controller.ex`):

1. **Verify first** — `FedifyClient.verify/1` before anything reads
   the payload (`inbox_controller.ex`, the `raw_body` assign). No parse before proof.
2. **Bind identity to content** — the signer's host travels with the
   activity, and `Instructions.trusted_inline_origin?/2`
   (`ap/instructions.ex:96`) refuses inline data whose claimed actor
   lives elsewhere. Forwarded activities get the narrow path only
   (independent re-fetch), never the trusting one.
3. **Classify at the edge, once** — `bun/handlers/inbox.ts` turns raw
   JSON-LD into a small typed *instruction*. Everything after the
   classifier handles instructions, not raw maps. Deep code never
   re-digs into remote JSON "just to grab one more field" — if a
   field is needed, the parser extracts it and the instruction
   carries it.

Same shape for the REST side: `Router` checks the bearer token
(scope-tagged routes), `decode_*_attrs` normalizes the body, the
context validates via changeset. A capability never re-checks auth
and a context never parses content-types.

## 3. Single-point predicates

Cross-cutting rules are **pure, named predicates** with exactly one
definition. The current set:

| Rule | The one place | Used by |
| --- | --- | --- |
| Who may see a note | `Notes.Read.visible_to?/2` (`notes/read.ex:61`) | single read, thread context, polls, interactions |
| Which rows a viewer's query may return | `WHERE` clauses + `scope_profile_statuses/3` (`notes/read.ex:87`, `timelines.ex:76,117`) | every timeline |
| Which hosts we may fetch/POST | `UrlGuard.safe?/1` (`url_guard.ex:20`; checked at `delivery/worker.ex:51`) | every outbound HTTP |
| Which HTML may be stored | `HTML.sanitize/1` + `HTML.Scrubber` (`html.ex:20`) | every content/bio changeset |
| Which inline AP data is trustworthy | `trusted_inline_origin?/2` (`ap/instructions.ex:96`) | every inbox instruction |

Rules for the set:

- **Pure.** A predicate takes data, returns a boolean/transform. No
  side effects, so it is unit-testable in isolation and free to call
  anywhere.
- **Never inline a copy.** If a new path needs "can X see Y", it
  calls `visible_to?/2` — even when the inline version would be one
  `cond` shorter. Two copies of a security rule is how the audit of
  2026-06-09 found the visibility leaks.
- **Extend the predicate, not the call site.** A new visibility kind
  is a new clause in `visible_to?/2` plus the matching `WHERE`
  filters — found by grepping the predicate's name, which is the
  point of giving it one.
- **New cross-cutting rule → new module-level predicate first**, then
  wire call sites through it. Don't grow it inside the first feature
  that needs it.

## 4. Writes: changeset is the gate, Multi is the envelope

- **Validation, coercion, length caps, and sanitization live in the
  changeset** (`Note.changeset/2`, `Account.changeset_remote/2` and
  `changeset_local/2`) — not
  in controllers, not in contexts. Anything inserted through the
  changeset is clean; therefore everything must be inserted through
  the changeset. Remote and local content take the *same* gate.
- **Sanitize on write, serve as-is on read.** The scrubber runs once
  per ingest, never per render. This is a security rule (no render
  path can forget it) and the performance rule (reads are free).
- **Domain write + event = one `Ecto.Multi`** with
  `Outbox.enqueue_multi/6` (`outbox.ex:55`). Side effects that must
  not be lost ride the transaction; side effects that may be lost
  (caches, metrics) stay out of it.

## 5. Reads: filter in SQL, hydrate in batch, render pure

- **Authorization is part of the query.** Timelines put visibility,
  blocks and mutes in the `WHERE` clause (`timelines.ex:76`); rows a
  viewer can't see are never fetched, so they can't leak and don't
  cost. Post-filtering fetched rows in Elixir is both the security
  smell and the performance smell.
- **One query per *shape*, not per item.** Preload associations in
  one pass (`timelines.ex:90`); fetch counts and viewer flags as
  id-keyed maps via `Notes.Counts.counts_for_notes/1`,
  `viewer_flags_many/2`, `reactions_for_notes/2`
  (`notes/counts.ex:60,123,221`). If new code calls `Repo` inside an
  `Enum.map` over notes/accounts, it's wrong — add or extend a
  `*_for_notes`-style batch function instead.
- **Views are pure.** `api/views/` render from structs plus the
  prefetched maps the capability hands them. A view that needs more
  data asks the capability to batch-fetch it; it never queries.

## 6. Egress: guard before send, sign in one place

- Every outbound HTTP request to a URL that *any* remote party
  influenced passes `UrlGuard.safe?/1` first — actor fetch, note
  fetch, media fetch, inbox POST. New egress path ⇒ new `safe?` call
  before the client call, plus a logged drop on `false`
  (`delivery/worker.ex:51` is the template).
- HTTP Signatures are produced only by `fedify.sign.v1` and verified
  only by `fedify.verify.v1`. No hand-rolled signature-base strings
  outside Bun.

## 7. Checklist for new code

Before opening a PR, walk the path of the new data:

- [ ] Untrusted bytes are verified (signature/token) **before** parsed,
      parsed **once** at the edge, and typed after.
- [ ] No raw remote JSON crosses into context modules.
- [ ] Any "may X …?" question calls an existing predicate, or adds a
      new pure one — never an inline copy.
- [ ] HTML reaches the DB only through a sanitizing changeset.
- [ ] List endpoints: associations preloaded, counts/flags batched,
      zero `Repo` calls per item, authorization in the `WHERE`.
- [ ] Outbound URL influenced by remote data passes `UrlGuard.safe?/1`.
- [ ] Durable side effects share the domain write's `Ecto.Multi`.
- [ ] Each function sits on one row of the layer map (§1).
- [ ] Matches assert rather than rebind: pins/literals in clauses, no
      `=` inside `if` conditions, compile is warning-clean (§8).

## 8. Pattern matching: the compiler holds the invariant

C codebases write `if (true == a)` so the `=`/`==` typo refuses to
compile. Same move here: write matches so a slip is a compile
warning or a loud `MatchError`, never a silently-wrong branch.

- **Branch on shape with matches, not `==` chains.** Function heads
  and `case` literals fail loudly when reality changes; an
  `if x == :thing` chain just takes the other branch. (`==` against
  a literal to *build a value* is fine.)
- **Pin what you compare.** In `case`/`with`/`receive` clauses a
  bare variable always matches — it *binds*, it doesn't compare.
  When the intent is "equals the existing binding", write
  `^expected ->`. A bare-variable clause shadowing an outer binding
  is a bug until proven otherwise (today: zero in tree; keep it so).
- **Assert results with a literal on the left.** When failure is a
  bug, `{:ok, x} = ...` / `:ok = ...` crashes at the cause.
  Discarding with `_ = ...` needs a comment saying why the result
  doesn't matter (`WebPush.subscribe/5` is the sanctioned shape).
- **No `=` inside `if`/`unless` conditions.** `if x = f()` is one
  keystroke from `if x == f()` and both compile. Bind on its own
  line, then branch — or use `case` on the value
  (`Media.sign_request/7`, `config/runtime.exs:62`).
- **Don't launder falsy values through sentinels.** `with`'s
  `true <- valid? || :invalid` breeds unreachable `false ->`
  clauses; match the falsy value in `else` directly
  (`web/viewer_controller.ex:50`).
- **Normalize untrusted truthiness once, strictly, at the edge.**
  Remote JSON booleans become exactly `value == true`
  (`ap/instructions/dms.ex:157`); anything else is `false`. Inside
  the boundary, booleans are booleans.
- **No dead clauses.** A clause the type system proves unreachable
  is recorded drift. `scripts/test-pglite.sh` compiles with
  `--warnings-as-errors`, so these fail the suite instead of
  scrolling past.
- **Match every RPC result.** `GatewayRpc.call` answers `{:ok, inner}`
  (inner shape = whatever the remote function returns, so `{:ok,
  {:ok, _}}` is normal) or transport `{:error, _}` → `rpc_error/1`.
  The type checker cannot see across `:rpc.call`, so these shapes are
  held by hand — an ignored result turns a gateway outage into a
  fake 200 (moderation, fixed 2026-06-12).

## 9. Known debt (recorded, not hidden)

Places that currently span layers; touch them by *shrinking* the mix,
and don't copy their shape:

- `api/capabilities/mastodon_accounts.ex` `create/1` — transport +
  RPC + error fan-out + token minting in one function.
- `api` `decode_*_attrs` content-type dispatch is duplicated per
  capability; a shared transport helper would remove the copies.
- `inbox_controller.ex` intake mixes URL reconstruction, verify,
  archive and dispatch — acceptable for an intake handler because
  each step is a guarded, ordered gate, but it should not grow.

## 10. Web client: the same rule, in CSS

The SPA (`web/`) obeys §0 in its own medium — every visual property in
one place, structure routing all elements through it. The analogue of a
copied predicate (§3) is a literal hex/px/rem in a component: it drifts,
and the drift is invisible until two screens disagree.

- **Tokens are the one place for value.** Colour, space, type and shape
  live in `web/src/styles/tokens.css` and nowhere else. Functional
  colour included: the single danger red is `--color-danger`
  (`tokens.css`), defined once — destructive actions and the `.error`
  box both derive from it, none re-type `#dc2626`.
- **A component class carries identity, not spacing.** `.btn`
  (`app.css`) is shape only — surface, border, radius, hover; padding is
  composed in the markup from spacing utilities (`.px-6 .py-2`,
  `base.css`), never baked in. Spacing spelled out in the markup makes
  "is this the same as that?" a glance instead of an audit, and the
  number is the token: `.px-3` is `var(--space-3)`. (`button` is styled
  by the `.btn` *class*, not a bare element rule, so `.tabs`/`.nav`
  buttons keep their own treatment — same reason predicates are named.)
- **Shared layout in one class, composed.** A centred reading-width
  column is `.measure` (`base.css`); a top-level element reaches for it
  rather than re-deriving `max-width + margin-inline: auto`. The copy
  that drifts is exactly how the login method-switch ended up left of
  its form on wide screens (fixed 2026-06-16, the CSS sibling of the
  2026-06-09 visibility leak).
- **Debt:** `.form` / `.timeline` / `.composer` / `.profile-head` /
  `.settings-form` / `.error` still inline the `max-width +
  margin-inline: auto` pair instead of composing `.measure`; migrate
  them when touched, don't add a sixth copy. Margin utilities
  (`.mt-N` …) aren't created yet — add to `base.css` in the same shape
  the first time one is needed, rather than reaching for an inline
  `margin`.
