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

## NATS (gateway, delivery, bun)

| Var | Required | Default | Notes |
|---|---|---|---|
| `NATS_HOST` | no | `127.0.0.1` | gateway/delivery only. Compose: `nats`. Kamal: `sukhi-fedi-nats`. |
| `NATS_PORT` | no | `4222` | gateway/delivery only. |
| `NATS_URL` | no | — | bun only. Full URL form, e.g. `nats://sukhi-fedi-nats:4222`. |
| `METRICS_PORT` | no | `4001` | delivery only. Prometheus scrape port for delivery worker metrics. |

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
| `ENABLED_CAPABILITIES` | no | all | API node only. Restrict which capability modules under `api/lib/sukhi_api/capabilities/` are mounted. Use to run specialised API nodes (e.g. admin-only). |

## Tuning — Oban concurrency (gateway, delivery)

Per-queue worker counts. Lower = lower steady-state RAM, slower
burst absorption. Raise on bigger boxes or when queue lag is
consistently >0 in `oban_jobs WHERE state='available'`.

| Var | Default | Service |
|---|---|---|
| `OBAN_MONITOR_CONCURRENCY` | `5` | gateway — NodeInfo poller fan-out |
| `OBAN_DELIVERY_CONCURRENCY` | `10` | delivery — outbound inbox POSTs |
| `OBAN_FEDERATION_CONCURRENCY` | `3` | delivery — fan-out / mention processing |

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
