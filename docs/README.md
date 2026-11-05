<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Documentation

> **Intent:** each document is listed by *whose question it answers*.
> **Reader's problem (hypothesis):** "which of these is for me?"
>
> The order is **what sukhi is → using it → running it → building it**. Technical
> material comes last. Each page answers one question; if unsure, start at the first
> row of your section. **(ja)** marks a page written in Japanese.

## 1. What sukhi is

| To know | Read |
| --- | --- |
| In a few lines | [`../README.md`](../README.md) |
| What a screen owes the person looking at it (nine promises) | [`KINDNESS.md`](KINDNESS.md) |
| Rethinking what is visible through the seven gifts that cost nothing | [`MUZAI_NO_SHICHISE.md`](MUZAI_NO_SHICHISE.md) (ja) |

## 2. Using it

| To know | Read |
| --- | --- |
| Joining, writing, notifications, moving, leaving | [`USING.md`](USING.md) / [`USING.ja.md`](USING.ja.md) |
| What a Mastodon app can do against sukhi | [`MASTODON_API.md`](MASTODON_API.md) |
| Reading a post in another language (translation, DeepL key) | [`TRANSLATION.md`](TRANSLATION.md) (and [quiet auto-translation](TRANSLATION_AUTO.md)) |
| What happens to feedback (the operator's side) | [`FEEDBACK.md`](FEEDBACK.md) |

## 3. Running your own server

Start at [`OPERATIONS.ja.md`](OPERATIONS.ja.md): prepare → first start → daily care.

**These guides exist only in Japanese (`.ja.md`). There is no English version yet.**
We would rather say so than hand you a machine translation; if you can help, please open an issue.

| To know | Read |
| --- | --- |
| Entry point, and who is responsible for what | [`OPERATIONS.ja.md`](OPERATIONS.ja.md) (ja) |
| Looking after other people's things without fear | [`CARING_FOR_YOUR_SERVER.ja.md`](CARING_FOR_YOUR_SERVER.ja.md) (ja) |
| ① Preparing the box | [`OPS_PREPARE.ja.md`](OPS_PREPARE.ja.md) (ja) |
| ② First start, updates, rollback | [`OPS_DEPLOY.ja.md`](OPS_DEPLOY.ja.md) (ja) |
| ③ Backups, updates, watching, when things go wrong | [`OPS_MAINTAIN.ja.md`](OPS_MAINTAIN.ja.md) (ja) |
| Getting started with SSH | [`OPERATING_OVER_SSH.ja.md`](OPERATING_OVER_SSH.ja.md) (ja) |
| Choosing and installing Docker / Podman | [`RUNTIME.ja.md`](RUNTIME.ja.md) (ja) |
| Swapping images in a Quadlet box | [`OPS_UPDATE_QUADLET.ja.md`](OPS_UPDATE_QUADLET.ja.md) (ja) |
| What visitors see while the app is stopped (maintenance page, read-only copy) | [`OPS_MAINTENANCE_PAGE.ja.md`](OPS_MAINTENANCE_PAGE.ja.md) (ja) |
| One private network for admin access (Tailscale) | [`TAILSCALE.ja.md`](TAILSCALE.ja.md) (ja) |
| Every environment variable | [`ENV.md`](ENV.md) |
| Where Datalevin keeps data, and its settings | [`DATALEVIN.md`](DATALEVIN.md) |
| Moving the delivery queue to SQLite | [`DELIVERY_QUEUE_MIGRATION.ja.md`](DELIVERY_QUEUE_MIGRATION.ja.md) (ja) |
| The bot gate (Anubis) | [`anubis.ja.md`](anubis.ja.md) (ja) |
| Swapping small static fixes without a release | [`static-override.ja.md`](static-override.ja.md) (ja) |
| Correcting data that went in wrong | [`data-correction.ja.md`](data-correction.ja.md) (ja) |
| Backups | [`../infra/backup/README.md`](../infra/backup/README.md) (ja) |
| Provisioning on OCI (Terraform) | [`../infra/terraform-x64-freetier/README.md`](../infra/terraform-x64-freetier/README.md) (ja) |

## 4. Building it

Start at [`DEVELOPING.md`](DEVELOPING.md), then [`ARCHITECTURE.md`](ARCHITECTURE.md).

| To know | Read |
| --- | --- |
| Run it locally, test it, who we learned from | [`DEVELOPING.md`](DEVELOPING.md) |
| The shape of the whole system (canonical) | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| Keeping security and speed in the structure | [`CODE_STYLE.md`](CODE_STYLE.md) |
| The addon contract | [`ADDONS.md`](ADDONS.md) |
| Running the tests | [`TESTING.md`](TESTING.md) |
| Which doors face the internet | [`web-surface.md`](web-surface.md) |
| What a press, key and back gesture do, per OS | [`UX_CONTRACT.md`](UX_CONTRACT.md) |
| How sukhi sounds in English, and why | [`ENGLISH_VOICE.md`](ENGLISH_VOICE.md) |
| The HTML / CSS subset we use | [`CSS_SUBSET.md`](CSS_SUBSET.md) (ja) |
| Datalevin data structure | [`DATALEVIN_SCHEMA.md`](DATALEVIN_SCHEMA.md) (ja) |
| Web Push: design, and what shipped | [`WEBPUSH.md`](WEBPUSH.md) |
| Making the backend unhurried | [`UNHURRIED_BACKEND.md`](UNHURRIED_BACKEND.md) (ja) |
| Four seams where native code could plug in | [`native-seams.md`](native-seams.md) |
| The web UI (web-next) | [`../web-next/README.md`](../web-next/README.md) (ja) |
| Load and anomaly watching (Julia) | [`METRICS_REPORT.md`](METRICS_REPORT.md), [`../analysis/README.md`](../analysis/README.md) |

## 5. Federation behaviour and specifications

| To know | Read |
| --- | --- |
| How this server speaks ActivityPub | [`FEDERATION.md`](FEDERATION.md) |
| Specifications implemented, and the ones sukhi wrote | [`specs/README.md`](specs/README.md) ([日本語](specs/README.ja.md)) |
| How sukhi meets Misskey | [`misskey-interop-sukhi.md`](misskey-interop-sukhi.md) |
| Pull Federation (sukhi's own protocol) | [`PULL_FEDERATION.md`](PULL_FEDERATION.md) |
| A proposal for declaring implemented specs | [`spec-declaration-notes.md`](spec-declaration-notes.md) |

## 6. Ahead (proposals; not built yet)

| Proposal | Read |
| --- | --- |
| Small independent communities inside sukhi.social | [`COMMUNITY_SUPPORT.md`](COMMUNITY_SUPPORT.md) (ja) |
| A server shell, `sukhi` | [`SERVER_SHELL.md`](SERVER_SHELL.md) (ja) |
| Writing federation intake as a reducer | [`FEDERATION_REDUCER.md`](FEDERATION_REDUCER.md) (ja) |
| Pulling everything you follow in bulk | [`PULL_FEDERATION_BULK.md`](PULL_FEDERATION_BULK.md) (ja) |
| The Misskey API | [`MISSKEY_API.md`](MISSKEY_API.md) |
| Not started / waiting on a decision | [`../TODO.md`](../TODO.md) / [`../OPEN_QUESTIONS.md`](../OPEN_QUESTIONS.md) (ja) |

## When you add a page

Before any technology, write two lines at the top: the **intent** (what it is for,
who for, how they should feel on leaving) and the **reader's problem** (what they
are stuck on). Until someone has told us the problem, call it a hypothesis.
