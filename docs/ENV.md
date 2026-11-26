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
| `INSTANCE_TITLE` | no | — | Deprecated; set `site_name` in the required `SUKHI_INSTANCE_CONFIG` file. |
| `GITOPS_STATUS_PATH` | no | `/run/sukhi-gitops/status.json` | `sukhi-gitops-sync` が書く状態ファイル。読むだけ。無ければ `/admin/system` に「更新」欄を出さない。 |

## Distributed Erlang (gateway ↔ api)

| Var | Required | Default | Notes |
|---|---|---|---|
| **`ERLANG_COOKIE`** / `RELEASE_COOKIE` | **yes** (prod) | `sukhi_fedi_dev_cookie` | Shared secret between `gateway` and `api`. **The default is a published string.** Anyone reachable on the EPMD port (4369) with the default cookie can execute arbitrary BEAM code (= RCE). Generate with `openssl rand -hex 32`. |
| **`SECRET_KEY_BASE`** | **yes** (prod) | — | Cookie-signing key for the `/admin` web UI session. Must be stable across deploys — rotating invalidates every logged-in admin session and forces re-login. Generate with `openssl rand -hex 64`. Treat as secret. |
| `RELEASE_DISTRIBUTION` | yes | — | Set to `name`. Wired into compose / Kamal already. |
| `RELEASE_NODE` | yes | — | `gateway@elixir` on gateway, `api@api` on api. Wired into compose / Kamal already. |
| `PLUGIN_NODES` | no | empty | Gateway only. Comma list of `<name>@<host>` Erlang nodes hosting plugin capabilities. Default `api@api`. |
| `GATEWAY_NODE` | no | — | API node only. Pin a specific gateway to RPC into. Usually inferred — set this only for multi-gateway topologies. |

## Job queues and raw bodies — PostgreSQL (gateway, delivery)

PostgreSQL holds Oban's `oban_jobs` (both nodes, one table) and the `raw_blobs`
table, and nothing else: the business data is in Datalevin (below). Both nodes
read the same variables.

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

## Store (gateway) — hosigraph

The business data is in hosigraph (over `dtlv` on the PATH); there is no other
store. `docs/STORE.md` says what works, what does not, and what to set on
a small box. A node that still sets `SUKHI_STORE` to anything but `datalevin`
refuses to start.

| Var | Required | Default | Notes |
|---|---|---|---|
| `SUKHI_INTAKE_FILE` | no | `/var/lib/sukhi/intake.json` | The marker the gateway writes when intake is closed/opened (JSON: state, since, reason, until, retry_after_s, settled_at, backup). For a static maintenance page to read while the gateway is down. A fresh start writes `open`. docs/OPS_DRAIN_BACKUP.ja.md §5. |
| `SUKHI_BACKUP_DIR` | no | `/var/lib/sukhi/backups` | Where `Maintenance.Backup` puts `<UTC stamp>/` (a `dtlv` copy of the data; PostgreSQL is not in it). The newest 3 complete ones are kept. docs/OPS_DRAIN_BACKUP.ja.md §4. |
| `SUKHI_HOSI_MIRROR` | no | off | `1`/`true`: copy the new people and posts of the store into hosigraph (`SukhiFedi.HosiMirror`). Only does anything in a build made with `SUKHI_HOSI=1` (a build-time switch, not read at runtime). docs/HOSI.md. |
| `SUKHI_HOSI_SHADOW` | no | off | `1`/`true`: also ask hosigraph the like view (how many favourited a post, and whether the viewer did), compare with the store's answer, and log when they differ. The answer on screen is still the store's. Needs `SUKHI_HOSI_MIRROR`. docs/HOSI.md. |
| `SUKHI_HOSI_DIR` | no | `<DATALEVIN_DIR>/hosi` | Where hosigraph keeps its files. It runs on the `dtlv` that `DATALEVIN_BIN` names. |
| `SUKHI_RAW_BACKEND` | no | `postgres` | Where large originals (`raw`) go: `postgres` (the `raw_blobs` table of the queue database) or `s3` (S3-compatible, same credentials as media). |
| `SUKHI_RAW_INLINE_MAX` | no | `4096` | Bytes of `raw` kept on the entity itself; larger is stored as a pointer. |
| `SUKHI_RAW_GRACE_S` | no | `86400` | How old an unreferenced blob must be before GC may delete it. |
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

## NATS (gateway, delivery)

| Var | Required | Default | Notes |
|---|---|---|---|
| `NATS_HOST` | no | `127.0.0.1` | gateway/delivery only. Compose: `nats`. Kamal: `sukhi-fedi-nats`. |
| `NATS_PORT` | no | `4222` | gateway/delivery only. |
| `NATS_ENABLED` | no | `true` | gateway only. `false`/`0`/`off`: no NATS connection, no `fedify.*` service, no WT telemetry subscription, and no startup NATS check. **Only for the single-BEAM `combined` release**, where delivery calls the fedify service in-process (the release sets `:sukhi_delivery, :fedify_service`) and a new post reaches the streaming feeds by a direct call. What stops: the WebTransport edge (it reads `stream.*` from NATS), and any gateway/delivery pair in separate BEAMs. With NATS on, `combined` still needs no NATS connection of its own for delivery. |
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
| `INSTANCE_CONTACT` | oldest local admin | A local username (with or without `@`) shown as the server's contact person: `contact_account` in `/api/v1/instance` and `contact.account` in `/api/v2/instance`, the way Mastodon's "contact username" works. Unset, or naming nobody here → the oldest local admin; no admin → `null`. |
| `JOIN_GREETER` | — | The name shown on the "ask to join" form as the person who looks at applications (`くろ`). Unset → a plain "the person who looks after this place" in each language. See [`JOIN.md`](JOIN.md). |
| `JOIN_CHECK_DAYS` | every day | Comma list of `mon,tue,wed,thu,fri,sat,sun`: the days it is fine to look at applications. The form and the receipt mail say "Thursday (in 3 days)" from this. |
| `JOIN_UTC_OFFSET_HOURS` | `9` | Where the day line falls for `JOIN_CHECK_DAYS`. |
| `LEGAL_FLAVOR` | — (required unless `legal.dir` is set) | Which bundled `/terms` and `/privacy` set to serve when `legal.dir` is unset: `sukhi` or `natadeco`. Any other value refuses to boot. Both are baked into the release. |
| `SUKHI_INSTANCE_CONFIG` → `legal.dir` | — (bundled) | Absolute path of a directory holding **this instance's own** `terms.<lang>.md` and `privacy.<lang>.md` (`ja`, `ko`, `en`; the same languages for both). Read and rendered once at boot; changing them takes a restart. A missing directory, an empty/unreadable file, a document missing in a language or an unsupported language refuses to boot. Unset → the bundled set `LEGAL_FLAVOR` names is served; with neither set, the gateway refuses to boot. The bundled sets are not anyone else's policy. |
| `PUBLIC_PREVIEW` | `off` | Server-rendered preview for logged-out visitors/crawlers: `off`, `meta` (OG / Twitter / JSON-LD head only) or `full` (plus a readable body). Public content only. |
| `PUBLIC_PREVIEW_ROBOTS` | `noindex, nofollow` | The meta-robots string on preview pages. Set `index, follow` to be crawled. |
| `SUKHI_INSTANCE_CONFIG` | `/etc/sukhi/instance.json` | Required mounted non-secret JSON for site metadata, optional `unauthenticated_redirect`, addon switches, `frontends` (`relay`, `web-next`, `web-simple`, `web-board`, `web-room`) and ordered routes. If routes are empty, `/` shows the frontend setup instructions. `nodeinfo_monitor` is disabled unless `addons.nodeinfo_monitor` is explicitly `true`. See `config/instance.json.example`. |
| `WEB_UPSTREAMS` | — | Removed. Define frontend URLs in `SUKHI_INSTANCE_CONFIG`. |
| `WEB_ROUTES` | — | Removed. Define route precedence and frontend selection in `SUKHI_INSTANCE_CONFIG`; first match wins. |
| `STATIC_OVERRIDE_DIR` | `/app/priv/static-override` | Where `/static/emojis/…` is read from: the custom emoji the importer drops on the host. Everything else under `/static/` comes from the release. See `docs/static-override.ja.md`. |
| `WT_TICKET_KEY` | — | Ed25519 seed (raw 32 bytes, base64) that signs WebTransport entry tickets. Unset → `/api/wt` answers 503. |
| `WT_ENDPOINT` | `https://webtransport.f3liz.casa/wt` | The WebTransport edge a ticket is for. |

## Translating posts (gateway)

Off until `LIBRETRANSLATE_URL` is set. What this is for, and what it will not do: [`TRANSLATION.md`](TRANSLATION.md).

| Var | Default | Notes |
|---|---|---|
| `LIBRETRANSLATE_URL` | — | The server's own translator: a [LibreTranslate](https://github.com/LibreTranslate/LibreTranslate) instance you run. The compose file has one ready (`docker compose --profile translate up -d`, image `sukhi-fedi-translate`, built from `translate/Dockerfile`); then set `LIBRETRANSLATE_URL=http://translate:5000`. Unset = no server translator (`translation.enabled` is `false`; people with their own DeepL key can still translate public posts). Keep it off the public internet — only the gateway should reach it. Our image loads only ja, en and ko (`LT_LOAD_ONLY`). |
| `LIBRETRANSLATE_API_KEY` | — | Sent in the request body when the instance requires a key. Treat as secret. |
| `TRANSLATE_MAX_FLIGHT` | `2` | How many translations run on that instance at once. More are told to come back in ten seconds. Provisional until a load test sets it. |

A person's own DeepL key is **not** an env var: each person brings theirs in settings; it is sealed with keys derived from `SECRET_KEY_BASE` (so rotating that secret makes every stored DeepL key unreadable — people enter theirs again).

## Release / test plumbing

Not operator knobs; listed so the audit (`scripts/env_audit.jl`) stays quiet.

| Var | Where | Notes |
|---|---|---|
| `RUNTIME_CONFIG_DIR`, `RELEASE_ROOT` | combined | Where `combined/config/runtime.exs` finds the three apps' runtime configs. `combined/Dockerfile` sets the first. |
| `PGRUST_PORT` | dev/test | The port the pgrust server listens on: `15434` under `make dev`, `15433` under `make test-pgrust`. |
| `PGRUST_DIR`, `PGRUST_CACHE` | dev/test | `PGRUST_DIR` uses a pgrust you installed (it holds `bin/postgres`); otherwise the script fetches one into `PGRUST_CACHE` (default `.pgrust/`). |
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

`nodeinfo_monitor` is intentionally different from the other addons: it is
disabled unless `addons.nodeinfo_monitor` is explicitly `true` in
`SUKHI_INSTANCE_CONFIG`. This keeps a normal SNS deployment from exposing or
starting the watcher just because the generic addon default is `all`.

## Delivery queue (delivery)

The delivery node's Oban runs on the same PostgreSQL as the gateway's
(`oban_jobs`), with queues of its own; each node runs only the queues its own
config names, so a job one inserts for the other's queue is picked up there.
The outbox row is in Datalevin and its dispatch job in PostgreSQL, so the hop
is at-least-once: the relay skips rows already queued, and
`delivery_receipts` absorbs any remaining duplicate. The relay polls the
outbox every 2 seconds (there is no LISTEN/NOTIFY).

The delivery node keeps its business data in the gateway's Datalevin store, so
it runs inside the `combined` release (one BEAM, one writer).

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
