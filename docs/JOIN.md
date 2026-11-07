<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Asking to join

> **Intent:** a person who wants to come in writes to someone who will answer, and is
> welcomed by name, instead of walking in with a code. The people who look after the
> place can see who is arriving.
> **Reader's problem (hypothesis; Hinata has decided the shape, nobody outside has used
> it yet):** "I would like to come in, but I don't know anyone here. Will anyone read
> what I write? When will I hear back? Is my address safe with strangers?"

This is the first of four steps (direction: 「いつも人が見えるように」, 2026-11-07).
Mocks: `web-next/ui-lab/mocks/join/`.

| Step | What | State |
| --- | --- | --- |
| 1 | Write → receipt mail → "did you get it?" → edit link | **here** |
| 2 | The greeter reads, welcomes; one-time 14-day entry link; sign-up through it; the invite-code screens give way | not yet |
| 3 | Reporting goes to a named person; mute/block while they rest | not yet |
| 4 | Admin screen for the greeter's name and days | not yet (env vars until then) |

## The path

1. **Write** (`/join`). Three questions, all optional: what to call you, where you heard
   of sukhi (if someone invited you, their nickname or handle), how you would like to
   spend time here. Then an email address, which is the only required field. The form
   says which day it will be looked at: "Thursday (in 3 days)".
2. **Check** (`/check`, the same gate as sign-in and sign-up). Mail goes out only after
   it; a script that posts straight to the form gets nothing sent.
3. **Receipt mail.** It carries the receipt number and the day. **Never what was
   written**, because the address may belong to someone else.
4. **"Did you get it?"** (`/join/asked`). The page shows the same number. *Yes* → the
   edit link is mailed. *No* → fix the address and the receipt goes again.
5. **Done** (`/join/done`). Replies come within a week; the goal is the day shown.
6. **Edit link** (`/join/edit/<key>`), from the second mail. Rewrite the words; the
   address does not move here.

An application nobody confirmed is **deleted after three hours**
(`JoinApplications.Sweeper`, every ten minutes). A mistyped address therefore does not
keep someone else's words around.

## Three keys

| Key | Held by | Used for | At rest |
| --- | --- | --- | --- |
| receipt number (6 digits) | printed in the mail and on the page | matching one to the other; **not a secret** | plain |
| `claim` | the browser that applied (its session) | saying "yes, I got the mail", or fixing the address | sha256 |
| edit `key` | the person, in the second mail | reading and rewriting the words | sha256 |

`claim` and `key` are 192 random bits and travel in request bodies, never URLs
(so they stay out of access logs, except the edit link itself, which is a page).
"Yes" can only come from the browser that wrote the application: someone who received a
receipt for an address that is not theirs cannot confirm it, and nobody who confirms
gets the words of anyone else.

## Where each guard lives

| Guard | Place |
| --- | --- |
| Shape of every field (trimmed; optional questions; length caps; address) | `Schema.JoinApplication` changesets |
| 10 writes / 15 min per peer for the whole `/api/v1/join` family | the gateway route (`plugin_limited/4` in the router) |
| 3 mails / 15 min per address | `JoinApplications` (`allow_mail/1`) |
| Mail only after the gate | `web-next` `/check` |
| Which day, and who | `JoinApplications.CheckDay` (env: [`ENV.md`](ENV.md)) |
| Three-hour deletion | `JoinApplications.purge_unconfirmed/1` via the sweeper |

## Layers

`web-next` (pages, session) → gateway `/api/v1/join*` → the api node
(`Capabilities.Join`, transport only) → `SukhiFedi.JoinApplications` over RPC.

- `GET /api/v1/join/info` → `{greeter, check_on, weekday, days_after}`
- `POST /api/v1/join` → `{receipt, claim, check_on, weekday, days_after}`
- `POST /api/v1/join/received {claim}`, `/join/email {claim, email}`
- `POST /api/v1/join/lookup {key}`, `/join/edit {key, call_name, found, hope}`

Statuses: 404 `join_not_found` (also: expired), 409 `join_confirmed`, 422
`validation_failed`, 429 `rate_limited`, 502 `send_failed`.

## Storage

Table `join_applications` (Postgres migration `20261107000001`; Datalevin takes it from
`priv/datalevin/catalog.exs`, a new table needs no Datalevin migration). Tests run on
both stores.

## Not here yet

- Reading and answering applications (step 2). Until then an applicant's words wait in
  the table with `confirmed_at` set; the greeter can read them with a query.
- The welcome mail needs a mailbox people can **reply** to; mails now go out from the
  no-reply address.
- `JOIN_GREETER` and `JOIN_CHECK_DAYS` move to an admin screen in step 4.
