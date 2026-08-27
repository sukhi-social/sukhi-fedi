# Setup Guide

---

## Requirements

| Tool             | Version                              |
| ---------------- | ------------------------------------ |
| Elixir           | ~> 1.20                              |
| OTP              | 27 (bundled with Elixir 1.20)        |
| PostgreSQL       | 16                                   |
| NATS             | 2 (plain core, no JetStream)         |
| Docker + Compose | any recent version                   |
| Bun              | 1.x — only for `bun/` fixtures/rollback (retired in prod, v0.3.0) |

---

## Quick Start (Docker Compose)

The fastest way to kick the tires — build the app images from source and run
the full stack locally, depending on no published images. The exact recipe
(minimal `.env`, the build-from-source override, the one `docker compose up
--build`) lives in the [repo README](README.md#quick-start--try-it-locally).

Migrations run automatically inside the gateway entrypoint on every boot, and
the SvelteKit SPA is baked into the gateway image — nothing to run by hand.
The app is at `http://localhost:4000` (the override publishes the port).

To tear down including volumes:

```bash
docker compose down -v
```

---

## Local Development

### 1. Start backing services

```bash
# PostgreSQL + NATS only (skip observability stack for dev)
docker compose up postgres nats
```

The base compose doesn't publish these to the host. For `mix` running on the
host, either add a `ports:` mapping (`5432:5432` / `4222:4222`) via an override,
or use `docker-compose.test.yml` (which publishes `15432` / `14222`) and point
`DB_*` / `NATS_*` at those ports.

### 2. Elixir

```bash
cd elixir
mix deps.get
mix ecto.create
mix sukhi.migrate       # walks core + enabled addons' migration dirs
iex -S mix
```

Note: `mise.toml` at the repo root pins Elixir/OTP to the versions the
Dockerfile builds with. Run `mise trust` once in the checkout and plain
`mix` picks them up — no per-command prefix.

### 3. The `fedify` service

There is no separate process to start. The `fedify.{ping,translate,sign,
verify,inbox}.v1` NATS Micro service — JSON-LD translation and HTTP-Signature
sign/verify — is served **natively in Elixir by `SukhiFedi.Fedi`**, in-process
on the gateway, on the queue group `fedify-workers` (no HTTP listener). It
starts with the gateway above.

The Bun worker under `bun/` that used to answer these subjects is retired
(v0.3.0); it's kept only for rollback and as the oracle that mints the golden
fixtures the native port is checked against. To run it (e.g. to regenerate
fixtures): `cd bun && bun install && bun run start`.

---

## Environment Variables

### Elixir

| Variable                      | Description                 | Default (dev)           |
| ----------------------------- | --------------------------- | ----------------------- |
| `DB_HOST`                     | PostgreSQL host             | `localhost`             |
| `DB_USER`                     | PostgreSQL user             | `postgres`              |
| `DB_PASS`                     | PostgreSQL password         | `postgres`              |
| `DB_NAME`                     | Database name               | `sukhi_fedi`            |
| `DB_POOL_SIZE`                | Connection pool size        | `10`                    |
| `NATS_HOST`                   | NATS host                   | `127.0.0.1`             |
| `NATS_PORT`                   | NATS port                   | `4222`                  |
| `PORT`                        | HTTP listen port            | `4000`                  |
| `DOMAIN`                      | Public hostname (no scheme) | `localhost:4000` (dev); **required in prod** |
| `ERLANG_COOKIE`               | Distributed-Erlang secret; the entrypoint refuses to boot on the dev default | `sukhi_fedi_dev_cookie` (dev only) |
| `SECRET_KEY_BASE`             | Admin session signing key   | dev default; **required in prod** (`openssl rand -hex 64`) |
| `ENABLED_ADDONS` / `DISABLE_ADDONS` | Addon selection (all three layers) | `all` / _(empty)_ |

Observability is OpenTelemetry-free by design (see ARCHITECTURE §9), so there
is no OTLP endpoint to configure.

---

## Ports

| Service                        | Port  | Exposure                       |
| ------------------------------ | ----- | ------------------------------ |
| Gateway (Elixir)               | 4000  | Public (incl. `/metrics`)      |
| Delivery metrics               | 4001  | Internal (`/metrics`)          |
| PostgreSQL                     | 5432  | Loopback only                  |
| NATS                           | 4222  | Internal                       |
| NATS HTTP API                  | 8222  | Internal                       |

---

## Database Migrations

Migrations live in `elixir/priv/repo/migrations/core/` (always-on) and
`elixir/priv/repo/migrations/addons/<id>/` (per-addon). The release
entrypoint (`elixir/rel/entrypoint.sh`) runs
`SukhiFedi.Release.migrate_all/0` automatically on every container
start, so Watchtower-driven upgrades apply new migrations without
operator intervention.

```bash
# Dev (walks core + all enabled addons' migration dirs)
cd elixir && mix sukhi.migrate

# Docker Compose (migrations run in the entrypoint; no manual step)
docker compose up -d

# One-off manual run
docker compose exec gateway bin/sukhi_fedi eval 'SukhiFedi.Release.migrate_all()'
```

---

## Observability

PromEx exposes Prometheus scrape endpoints inside each Elixir node:

- **Gateway** — `GET http://localhost:4000/metrics`
- **Delivery** — `GET http://localhost:4001/metrics`

Point any external Prometheus / Grafana / Jaeger stack at those
endpoints; the compose file does not bundle one.

---

## Production Deployment

Self-hosted flow: **Terraform** provisions the VM (cloud-init runs on first
boot to install Docker, mount the block volume, and harden the OS) →
**docker compose up -d** pulls pinned images from GHCR → **Watchtower** keeps
them fresh.

Two Terraform stacks available:

- `infra/terraform/` — ARM64 `VM.Standard.A1.Flex` (2 OCPU / 12 GB default)
- `infra/terraform-x64-freetier/` — x64 `VM.Standard.E2.1.Micro` (1 OCPU /
  1 GB, Always Free). Trades RAM for wider AD availability. See that
  directory's README for the memory-tight BEAM/PG tuning.

### Step 1 — Provision with Terraform

Creates the OCI VM, VCN/subnet, and a block volume mounted at `/mnt/data`
(used by PostgreSQL). cloud-init on first boot installs
Docker CE, creates the `deploy` user with your SSH key, locks down UFW
(SSH only; Cloudflare Tunnel handles HTTP ingress), tunes sysctl, and
creates a swap file on RAM-tight hosts.

```bash
cd infra/terraform                 # or infra/terraform-x64-freetier
cp terraform.tfvars.example terraform.tfvars
# fill in tenancy_ocid, user_ocid, fingerprint, private_key_path,
# tenancy_namespace, domain, etc.
terraform init
terraform apply
# outputs: instance_public_ip, ssh_command

# wait for cloud-init to finish (3–5 min on first boot)
ssh ubuntu@$(terraform output -raw instance_public_ip) 'cloud-init status --wait'
```

### Step 2 — Deploy with docker compose + Watchtower

Copy this repo (or the `sukhi-fedi-starter` skeleton) to the VM and set
`.env` with a version pin and any feature toggles:

```
SUKHI_REPO_OWNER=f3liz-casa  # where the published images live
SUKHI_VERSION=v0             # :v0 rolls with each patch release; pin :v0.1.x to freeze
DOMAIN=example.tld
ERLANG_COOKIE=<openssl rand -hex 32>
SECRET_KEY_BASE=<openssl rand -hex 64>
ENABLED_ADDONS=all           # or a comma list: mastodon_api,streaming,moderation
ADDON_PRESETS=               # optional bundle: mastodon_compatible,server_version_watcher
WATCHTOWER_POLL_INTERVAL=3600
```

> The maintainer's own instance (`sukhi.f3liz.casa`) deploys via Kamal from a
> separate private repo (`sukhi-social/sukhi-deploy`); this section describes
> the generic docker-compose + Watchtower self-host path.

Then:

```bash
docker compose pull
docker compose up -d
```

Migrations run inside the `gateway` entrypoint on every start, so first
boot and subsequent upgrades are symmetric.

### Upgrades

Nothing to do. Watchtower polls GHCR every `WATCHTOWER_POLL_INTERVAL`
seconds, pulls the new image when the `:v0` / `:v0.1` / `:v0.1.2` tag
you pinned moves, and recreates `gateway` / `api` containers.
Stateful `postgres` / `nats` containers are left alone.

To force an upgrade immediately:

```bash
docker compose pull gateway api
docker compose up -d gateway api
```

To pin a specific version (opt out of auto-update):

```bash
# in .env
SUKHI_VERSION=v0.1.2
```

### Logs

```bash
docker compose logs -f gateway
docker compose logs -f api
```

---

## Scaling

The app nodes are stateless — all state lives in Postgres and NATS — so scale
by adding gateway replicas:

```bash
docker compose up -d --scale gateway=3
```

The native `fedify.*.v1` service runs in-process on each gateway and shares the
`fedify-workers` NATS Micro queue group, so it scales with the gateways
automatically. `Outbox.Relay`'s `FOR UPDATE SKIP LOCKED` likewise lets multiple
delivery instances cooperate, each claiming a disjoint batch.
