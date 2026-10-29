# Environment variables

A single reference for every env var the stack reads. Organized by
service — pick the column for the deploy target you care about
(Compose / Coolify / Kamal all read the same vars).

Required vars are marked **bold**. The release boots with `fetch_env!`
on those and dies loudly at startup if they're missing — better than
silently minting URLs under `localhost`.

Defaults shown are the *runtime* defaults (what the app uses if the
env is unset). Compose / Kamal files may inject their own values on
top — those win.

---

## Identity (all services)

| Var | Required | Default | Notes |
|---|---|---|---|
| **`DOMAIN`** | **yes** (prod) | `localhost:4000` (dev) | Public hostname, no scheme, no port. Stamped into ActivityPub IDs and HTTP-Sig `keyId`. **Changing this after users exist strands their fediverse identity** — set it right before the first signup. |
| `INSTANCE_TITLE` | no | `sukhi-fedi` | Display name in `/api/v1/instance` and `/.well-known/nodeinfo/2.0`. |

## Distributed Erlang (gateway ↔ api)

| Var | Required | Default | Notes |
|---|---|---|---|
| **`ERLANG_COOKIE`** / `RELEASE_COOKIE` | **yes** (prod) | `sukhi_fedi_dev_cookie` | Shared secret between `gateway` and `api`. **The default is a published string.** Anyone reachable on the EPMD port (4369) with the default cookie can execute arbitrary BEAM code (= RCE). Generate with `openssl rand -hex 32`. |
| **`SECRET_KEY_BASE`** | **yes** (prod) | — | Cookie-signing key for the `/admin` web UI session. Must be stable across deploys — rotating invalidates every logged-in admin session and forces re-login. Generate with `openssl rand -hex 64`. Treat as secret. |
| `RELEASE_DISTRIBUTION` | yes | — | Set to `name`. Wired into compose / Kamal already. |
| `RELEASE_NODE` | yes | — | `gateway@elixir` on gateway, `api@api` on api. Wired into compose / Kamal already. |
| `PLUGIN_NODES` | no | empty | Gateway only. Comma list of `<name>@<host>` Erlang nodes hosting plugin capabilities. Default `api@api`. |
| `GATEWAY_NODE` | no | — | API node only. Pin a specific gateway to RPC into. Usually inferred — set this only for multi-gateway topologies. |

## Database (gateway, delivery)

| Var | Required | Default | Notes |
|---|---|---|---|
| **`DB_USER`** | **yes** (prod) | — | Postgres username. |
| **`DB_PASS`** | **yes** (prod) | — | Postgres password. Treat as secret. |
| `DB_HOST` | no | `localhost` | Container DNS name. Compose: `postgres`. Kamal: `sukhi-fedi-postgres`. |
| `DB_NAME` | no | `sukhi_fedi` | Database name. |
| `DB_POOL_SIZE` | no | `10` (gateway) / `5` (delivery) | Ecto pool. Tune up if `pg_stat_activity` shows constant waits. |
| `DB_QUEUE_TARGET_MS` / `DB_QUEUE_INTERVAL_MS` | no | `50` / `1000` | Gateway pool: a checkout that has waited past the target for a whole interval is dropped (503 `busy`). Raise only if drops happen while the DB is idle. |
| `RPC_MAX_IN_FLIGHT` | no | `64` | Backstop: calls from the api node that may run on the gateway at once (`SukhiFedi.RpcGate`); the next gets `{:badrpc, :overloaded}` → 503. The queue below normally keeps this from being reached. |
| `ADMISSION_MAX_IN_FLIGHT` | no | `64` | `/api/*` requests running at once (`Web.AdmissionQueue`). The next gets `503` + `x-queue-ticket` + its place in line; the client comes back for its turn. |
| `ADMISSION_HOLD_MS` | no | `300` | How long a request waits for a slot before it is given a ticket (and a ticket holder before it is told to come back). |
| `ADMISSION_MAX_WAIT_MS` | no | `15000` | A place in line expected to take longer than this is refused up front: a plain 503 with `retry-after` and `x-slow-down`, so the client stays away rather than queue for longer than a person will wait. |
| `ADMISSION_MAX_WAIT_BG_MS` | no | `120000` | The same limit for requests that send `x-sukhi-purpose: background` (polls, read-marker syncs — nobody watching): they queue behind every interactive request and are refused only past this. |
| `ADMISSION_QUEUE_MAX` | no | `500` | Longest line. Past it, a plain 503 with no ticket. |

## Store (gateway) — Datalevin instead of Postgres

Off by default. `docs/DATALEVIN.md` says what works, what does not, and
what to set on a small box.

| Var | Required | Default | Notes |
|---|---|---|---|
| `SUKHI_STORE` | no | `postgres` | `datalevin` keeps the business data in Datalevin (`dtlv` on the PATH) and runs Oban on SQLite. The `DB_*` vars are then unused by the gateway. |
| `SUKHI_QUEUE_DB` | no | `/var/lib/sukhi/queue.db` | datalevin mode: the SQLite file Oban lives in. |
| `SUKHI_QUEUE_SYNCHRONOUS` | no | `full` | datalevin mode: SQLite `synchronous` (`full`, `normal`, `off`). |
| `SUKHI_QUEUE_POOL_SIZE` | no | `5` | datalevin mode: SQLite pool. |
| `SUKHI_GRAPH` | no | off | `1`/`true`: run the graph store (`<DATALEVIN_DIR>/graph`, its own `dtlv`) beside the main database and copy each admitted inbound activity into it. Best-effort; never changes what the inbox answers. docs/DATALEVIN_SCHEMA.md. |
| `SUKHI_GRAPH_READ` | no | off | `1`/`true` (with `SUKHI_GRAPH`): the public (local), hashtag and list timelines pick their page from the graph; the notes themselves still come from the relational store. A short page, a forward cursor (`since_id`/`min_id`), `only_media`/`hide_sensitive`, or any graph failure falls back to the relational query. |
| `SUKHI_GRAPH_SWEEP` | no | dry-run | `execute` lets the daily sweep delete remote objects; anything else only logs what it would delete. |
| `SUKHI_GRAPH_TTL_FOLLOWED_DAYS` / `SUKHI_GRAPH_TTL_OTHER_DAYS` | no | `90` / `14` | How long a remote object stays after it was last received or touched (followed authors / everyone else). |
| `SUKHI_GRAPH_SWEEP_LIMIT` | no | `2000` | Candidates examined per sweep run. |
| `SUKHI_GRAPH_SIZE_BUDGET_MB` | no | unset | Over this size on disk, the sweep halves both TTLs for that run. |
| `SUKHI_RAW_BACKEND` | no | `sqlite` | datalevin mode: where large originals (`raw`) go: `sqlite` (a table in the queue file) or `s3` (S3-compatible, same credentials as media). |
| `SUKHI_RAW_INLINE_MAX` | no | `4096` | datalevin mode: bytes of `raw` kept on the entity itself; larger is stored as a pointer. |
| `SUKHI_RAW_GRACE_S` | no | `86400` | datalevin mode: how old an unreferenced blob must be before GC may delete it. |
| `SUKHI_RAW_BUCKET` | no | `S3_BUCKET` | `SUKHI_RAW_BACKEND=s3`: bucket for blobs (keys `raw/sha256/<xx>/<hex>`). |
| `SUKHI_SUDACHI_URL` | no | — | Sudachi segmentation service (`POST /segment`). Unset: Japanese text is indexed unsegmented. |
| `DATALEVIN_DIR` | no | `/var/lib/sukhi/datalevin` | Database directory. |
| `DATALEVIN_BIN` | no | `dtlv` | The native `dtlv` binary. |
| `DATALEVIN_DURABILITY` | no | `strict` | `strict` / `relaxed` / `extra` (write-ahead log), `lmdb` (no log, sync per commit), `nosync` (no log, no sync; tests only). |
| `DATALEVIN_MAP_SIZE_MB` | no | `1024` | LMDB map size. A ceiling on the data file, not memory; raise it before the data nears it. |
| `DATALEVIN_XMX` | no | `96m` | GraalVM heap cap of the `dtlv` process. `0` / `none` leaves it uncapped. |
| `DATALEVIN_RUNTIME_ARGS` | no | empty | Extra native-image runtime flags, space separated. |
| `DATALEVIN_WAL_GROUP_COMMIT` / `_MS` | no | dtlv's | Commits grouped per fsync, and the longest wait for a group. |
| `DATALEVIN_WAL_RETENTION_MB` / `_HOURS` | no | `256` / `24` | How much log is kept. dtlv's own default (8 GiB / 7 days) is too much for a small disk. |
| `DATALEVIN_WRITE_BATCH_DELAY_US` / `_SIZE` | no | dtlv's | Async write batching. |
| `DATALEVIN_CACHE_LIMIT` | no | dtlv's | Datalevin's own cache bound. |
| `DATALEVIN_BATCH` | no | `500` | Rows per request when writing in bulk (max 5000). |
| `DATALEVIN_TIMEOUT_MS` | no | `30000` | One request to `dtlv`. |

## NATS (gateway, delivery, bun)

| Var | Required | Default | Notes |
|---|---|---|---|
| `NATS_HOST` | no | `127.0.0.1` | gateway/delivery only. Compose: `nats`. Kamal: `sukhi-fedi-nats`. |
| `NATS_PORT` | no | `4222` | gateway/delivery only. |
| `NATS_URL` | no | — | bun only. Full URL form, e.g. `nats://sukhi-fedi-nats:4222`. |
| `METRICS_PORT` | no | `4001` | delivery only. Prometheus scrape port for delivery worker metrics. |

## Media storage — S3 / rustfs (gateway)

Unset `S3_ENDPOINT` means no object storage: uploads return `not_configured`.
When it is set, the credentials are required (`fetch_env!` at boot).
`config/runtime.exs` is the only place these are read; the presigned-upload
path takes its credentials, region and bucket from the same config.

| Var | Required | Default | Notes |
|---|---|---|---|
| `S3_ENDPOINT` | no | — | e.g. `https://<account>.r2.cloudflarestorage.com`; in prod the rustfs accessory |
| **`S3_ACCESS_KEY_ID`** / **`S3_SECRET_ACCESS_KEY`** | yes, with `S3_ENDPOINT` | — | The names ExAws uses. (`S3_ACCESS_KEY` / `S3_SECRET_KEY` are not read.) |
| `S3_REGION` | no | `us-east-1` | |
| `S3_BUCKET` | no | `media` | Uploaded media |
| `S3_INBOUND_BUCKET` / `S3_OUTBOUND_BUCKET` | no | `inbound` / `outbound` | Archived federation payloads |
| `S3_PUBLIC_URL` | no | — | CDN base for presigned uploads' `public_url` |

## Signup, legal pages, previews (gateway)

| Var | Default | Notes |
|---|---|---|
| `INVITE_REQUIRED` | `true` | `false` lets anyone register. A mailbox is still verified either way. |
| `LEGAL_FLAVOR` | `sukhi` | Which `/terms` and `/privacy` set to serve: `sukhi` or `natadeco`. Both are baked into the release. |
| `PUBLIC_PREVIEW` | `off` | Server-rendered preview for logged-out visitors/crawlers: `off`, `meta` (OG / Twitter / JSON-LD head only) or `full` (plus a readable body). Public content only. |
| `PUBLIC_PREVIEW_ROBOTS` | `noindex, nofollow` | The meta-robots string on preview pages. Set `index, follow` to be crawled. |
| `SSR_URL` | — | When set (natadeco: `http://natadeco-ssr:3000`), pages that would get the empty SPA shell are forwarded to this SSR server. |
| `STATIC_OVERRIDE_ONLY` | — | `true` = `STATIC_OVERRIDE=only` (kept for natadeco). See `docs/static-override.md`. |
| `WT_TICKET_KEY` | — | Ed25519 seed (raw 32 bytes, base64) that signs WebTransport entry tickets. Unset → `/api/wt` answers 503. |
| `WT_ENDPOINT` | `https://webtransport.f3liz.casa/wt` | The WebTransport edge a ticket is for. |

## Release / test plumbing

Not operator knobs; listed so the audit (`scripts/env_audit.jl`) stays quiet.

| Var | Where | Notes |
|---|---|---|
| `RUNTIME_CONFIG_DIR`, `RELEASE_ROOT` | combined | Where `combined/config/runtime.exs` finds the three apps' runtime configs. `combined/Dockerfile` sets the first. |
| `PGLITE` | dev/test | `1` points the DB config at the embedded PGlite (`make test-pglite`). |
| `S3_HOST`, `S3_PORT` | test | The mock S3 the test config talks to (`127.0.0.1:19000`). |

## Transactional mail (gateway)

Email verification + login codes go out through `SukhiFedi.Mailer`.
With `SMTP_HOST` unset the log transport is used: mails land in the
gateway log instead of a mailbox — fine for dev, visibly broken on
purpose in prod.

| Var | Required | Default | Notes |
|---|---|---|---|
| `SMTP_HOST` | no | — (log transport) | SMTP relay. OCI Email Delivery: `smtp.email.<region>.oci.oraclecloud.com` (Osaka: `ap-osaka-1`). Setting it makes the other four **required** (`fetch_env!`). |
| `SMTP_PORT` | no | `587` | STARTTLS submission port. The Mailer always negotiates TLS and verifies the server certificate. |
| `SMTP_USERNAME` | with `SMTP_HOST` | — | OCI: an IAM user's *SMTP credential* username (long OCID form). Treat as secret. |
| `SMTP_PASSWORD` | with `SMTP_HOST` | — | Shown exactly once at credential generation. Treat as secret. |
| `MAIL_FROM` | with `SMTP_HOST` | `no-reply@localhost` (dev) | The From/envelope sender. OCI: must be a registered **approved sender** in the same region; pair with the SPF/DKIM records on its domain. |

## Addons (gateway, api)

The addon system gates feature surface (Mastodon API, federation
endpoints, web push, moderation, etc.). See [`docs/ADDONS.md`](ADDONS.md).

| Var | Required | Default | Notes |
|---|---|---|---|
| `ENABLED_ADDONS` | no | `all` | Comma list of addon ids, or literal `all`. |
| `DISABLE_ADDONS` | no | empty | Deny-list overlay on top of `ENABLED_ADDONS`. Deny wins. |
| `ADDON_PRESETS` | no | empty | Comma list of preset ids. Expanded and unioned with `ENABLED_ADDONS`. Example: `server_version_watcher` for a federation-watcher-only deploy. |
| `OJAK_SHADOW` | no | unset | `1` → verifiers also ask ojak-ex and log disagreements (their own answer is still used). See README, "Native signature library". |
| `OJAK_LD_BACKEND` | no | `native` | `ojak` → RsaSignature2017 sign/verify through ojak-ex. |
| `OJAK_NIF_BUILD` | no | unset | Build time only: `1` builds ojak-ex's native library with Rust instead of downloading the prebuilt one. |
| `ENABLED_CAPABILITIES` | no | all | API node only. Restrict which capability modules under `api/lib/sukhi_api/capabilities/` are mounted. Use to run specialised API nodes (e.g. admin-only). |

## Delivery queue backend (delivery)

Default is Postgres. `DELIVERY_QUEUE=sqlite` moves the `delivery` and
`outbox_dispatch` queues to a single-node SQLite file (Oban Lite); every
other queue and all business data stay in Postgres (`delivery` is also still
drained from Postgres, because the gateway enqueues follow/quote/relay sends
there). One node only: the file
is not shared. The outbox → queue hop becomes at-least-once (the relay skips
rows already queued; `delivery_receipts` absorbs any remaining duplicate).

In a combined release the gateway also enqueues its `delivery` sends (follow
Accepts, quotes, relays) into the SQLite queue (`:delivery_oban`), and its
`DeliveryStatus` and discarded-job count read the SQLite file
(`:extra_job_repos`). A separate gateway node cannot see the file, so it keeps
using Postgres, which the delivery node still drains.


| Var | Default | Meaning |
|---|---|---|
| `DELIVERY_QUEUE` | `postgres` | `postgres` or `sqlite` |
| `DELIVERY_QUEUE_DB` | `/var/lib/sukhi/delivery_queue.db` | SQLite file (directory must exist) |
| `DELIVERY_QUEUE_SYNCHRONOUS` | `full` | `full` or `normal` (WAL; `normal` can lose the last commits on power loss) |
| `DELIVERY_QUEUE_POOL_SIZE` | `5` | SQLite connection pool |
| `DELIVERY_QUEUE_HANDOVER` | `1` | `0` で起動時の Postgres → SQLite 自動移管を止める (docs/DELIVERY_QUEUE_MIGRATION.md) |
| `DELIVERY_QUEUE_RETENTION_SECONDS` | `2592000` | Pruner max age for finished jobs |

## Tuning — Oban concurrency (gateway, delivery)

Per-queue worker counts. Lower = lower steady-state RAM, slower
burst absorption. Raise on bigger boxes or when queue lag is
consistently >0 in `oban_jobs WHERE state='available'`.

| Var | Default | Service |
|---|---|---|
| `OBAN_MONITOR_CONCURRENCY` | `5` | gateway — NodeInfo poller fan-out |
| `OBAN_DELIVERY_CONCURRENCY` | `10` | delivery — outbound inbox POSTs |
| `OBAN_FEDERATION_CONCURRENCY` | `3` | delivery — fan-out / mention processing |
| `OBAN_PUSH_CONCURRENCY` | `3` | delivery — Web Push sends |
| `OBAN_OUTBOX_DISPATCH_CONCURRENCY` | `2` | delivery — outbox rows to NATS |
| `OBAN_INBOUND_ARCHIVE_CONCURRENCY` | `10` | gateway — archive inbound payloads |
| `OBAN_OUTBOUND_ARCHIVE_CONCURRENCY` | `10` | gateway — archive outbound payloads |
| `OBAN_PUBLISH_CONCURRENCY` | `5` | gateway — publish jobs |
| `OBAN_PREVIEW_CONCURRENCY` | `3` | gateway — link-preview fetches |
| `OBAN_BACKFILL_CONCURRENCY` | `2` | gateway — remote outbox backfill |

## Pull Federation (gateway, delivery)

See [PULL_FEDERATION.md](PULL_FEDERATION.md). Set `PULL_FEDERATION` the
same on both services.

| Var | Default | Service |
|---|---|---|
| `PULL_FEDERATION` | `on` | both — `off` stops advertising the capability (FEP-844e discovery), answers `/pull/v1/*` with 404, and pushes to every follower |
| `PULL_MAX_STREAMS` | `16` | gateway — concurrent `GET /pull/v1/stream` we serve; more get 429 + `Retry-After` |
| `PULL_MAX_CONCURRENT` | `4` | gateway — concurrent pulls we run against other servers |

## Tuning — Finch HTTP pool (delivery)

Outbound TLS connection pool to remote inboxes. Lower on memory-
constrained hosts; raise if `sukhi_delivery_pool_utilization` stays
near 1.0 under load.

| Var | Default |
|---|---|
| `FINCH_POOL_SIZE` | `50` |
| `FINCH_POOL_COUNT` | `4` |

## Tuning — BEAM (gateway, delivery)

Passed through Docker env. The release respects them.

| Var | Recommended | Notes |
|---|---|---|
| `ERL_FLAGS` | `+S <cores>:<cores> +SDcpu <cores>:<cores> +SDio <2× cores> +MBas aobf +MHas aobf` | Match scheduler count to available cores. `+MBas/+MHas aobf` reduces long-tail binary heap fragmentation, important for nodes that handle lots of JSON. |
| `ERL_FULLSWEEP_AFTER` | `20` (normal) / `10` (tight memory) | Full GC interval. Lower = more aggressive memory return to OS at minor CPU cost. |
| `ERL_MAX_PORTS` | `4096` | Lift if you hit `:emfile`-style errors under extreme load. Default usually fine. |

## Telemetry (gateway)

| Var | Required | Default | Notes |
|---|---|---|---|
| `METRICS_TOKEN` | no | — | Bearer for **both** `GET /metrics` (Prometheus scrape) and `GET /api/metrics` (JSON snapshot + stored history). Unset means those two paths answer `404` — telemetry off, not open. Generate with `openssl rand -hex 32`, and give it to your scraper as `Authorization: Bearer …`. Treat as secret. |

`/metrics` was open until 2026-08-28. It carries nothing personal, but it
does name every dependency and its exact version, the internal database
host and name, every table, and the shape of the load — which is the
homework someone looking for a known vulnerability would otherwise have
to do themselves. Closed by default now; see
[`web-surface.md`](web-surface.md).

## Container build / image pulls

These aren't read by the app — they're consumed by Docker Compose /
Kamal to pick which image tag to pull.

| Var | Required | Default | Notes |
|---|---|---|---|
| `SUKHI_REPO_OWNER` | no | `nyanrus` | GHCR org. Forks need to override. |
| `SUKHI_VERSION` | no | `v0` (was `v1` historically) | Image tag. `v0` follows latest patch; `v0.1.37` pins. |
| `KAMAL_REGISTRY_PASSWORD` | yes (Kamal) | — | GitHub PAT with `read:packages` for ghcr.io pulls. |

## Postgres container env

Consumed by the postgres image at first init, not by the app.

| Var | Default | Notes |
|---|---|---|
| `POSTGRES_USER` | `postgres` | Must match `DB_USER` set on gateway/delivery. |
| `POSTGRES_PASSWORD` | `postgres` | Must match `DB_PASS`. Override on any deploy that other workloads can reach the Docker network. |
| `POSTGRES_DB` | `sukhi_fedi` | Must match `DB_NAME`. |

---

## Minimum viable env

For a fresh production deploy, only these need values **you supply**:

```bash
# Identity
DOMAIN=sukhi.f3liz.casa
INSTANCE_TITLE="sukhi.f3liz.casa"

# Secrets
ERLANG_COOKIE="$(openssl rand -hex 32)"
SECRET_KEY_BASE="$(openssl rand -hex 64)"
DB_PASS="$(openssl rand -hex 24)"
POSTGRES_PASSWORD="$DB_PASS"
DB_USER=sukhi
POSTGRES_USER=sukhi

# Image source
SUKHI_REPO_OWNER=f3liz-casa
SUKHI_VERSION=v0

# Mail (signup verification / login codes). Optional — but without it
# codes only land in the gateway log, so real signups can't verify.
SMTP_HOST=smtp.email.ap-osaka-1.oci.oraclecloud.com
SMTP_USERNAME="<IAM user → SMTP credentials>"
SMTP_PASSWORD="<shown once at generation>"
MAIL_FROM=no-reply@sukhi.f3liz.casa
```

Everything else has sane defaults wired into compose / Kamal config.

---

## Migration-safe changes

Variables you can change without restarting users:

- `INSTANCE_TITLE`, `ENABLED_ADDONS`, `DISABLE_ADDONS`, `ADDON_PRESETS`
- All `OBAN_*`, `FINCH_*`, `ERL_FLAGS`, `ERL_FULLSWEEP_AFTER`
- `DB_POOL_SIZE`

Variables that **break federation if changed after first run**:

- `DOMAIN` — strands every ActivityPub ID minted under the old host
- `DB_NAME`, `DB_USER`, `DB_PASS` (without migrating data) — gateway / delivery can't reach the old DB

Variables that **break local clustering if rotated unilaterally**:

- `ERLANG_COOKIE` — gateway and api must be redeployed together

---

## Where each is read

For grep navigation if you're tracking a specific var:

- gateway: `elixir/config/runtime.exs`, `elixir/lib/sukhi_fedi/config.ex`
- delivery: `delivery/config/runtime.exs`, `delivery/lib/sukhi_delivery/config.ex`
- api: `api/config/runtime.exs`, `api/lib/sukhi_api/config.ex`
- bun: `bun/` (TS-side; uses `process.env.NATS_URL` etc.)
