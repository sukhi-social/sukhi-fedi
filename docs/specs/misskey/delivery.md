<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Delivery behaviour

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

## In one paragraph

Misskey retries a failed delivery for more than a day. sukhi retries for about twenty minutes, so a short outage at Misskey can lose a delivery from sukhi.

Source of this page: **[study]**

- Misskey groups followers by shared inbox and falls back to the personal inbox.
- Retries: BullMQ, 12 attempts by default, delay `(2^n - 1)` minutes up to 8 hours, about 1.3 days in total (calculated).
- Misskey does not retry most 4xx answers, except 429. It stops delivering to a server that answers 410 on a shared inbox, and to a server that has not answered for one week.
- For sukhi, which retries for about 20 minutes (calculated), a short outage on the Misskey side can drop a delivery.
