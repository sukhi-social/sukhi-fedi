<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Delivery behaviour

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

Misskey retries a failed delivery for more than a day, and gives up on servers that stay silent for a week.

Source of this page: **[study]**

- Misskey groups followers by shared inbox and falls back to the personal inbox.
- Retries: BullMQ, 12 attempts by default, delay `(2^n - 1)` minutes up to 8 hours, about 1.3 days in total (calculated).
- Misskey does not retry most 4xx answers, except 429. It stops delivering to a server that answers 410 on a shared inbox, and to a server that has not answered for one week.
