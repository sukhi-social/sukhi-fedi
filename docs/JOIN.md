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
| 1 | Write → receipt mail → "did you get it?" → edit link | here |
| 2 | The greeter reads (web-gov), welcomes or gently declines; one-time 14-day entry link; sign-up through it without an invite code | **here** |
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
7. **Greeter** (web-gov, below). Reads the confirmed applications, then either
   - **welcomes**: a mail with a one-time entry link (`/welcome/<key>`, 14 days) and the
     greeter's own line; or
   - **declines**: a gentle mail with the greeter's own words.

   Either way the words and the address are **deleted once the mail has gone out**; what
   stays is the receipt number, the dates, and an `admin_audits` row (`join_welcomed` /
   `join_declined`, the receipt number only).
8. **Entry link** (`/welcome/<key>`). The key moves into the session (not the URL) and
   the visitor goes to `/signup` with the invite-code field hidden; sign-up sends the
   key, and the account is created and the key spent in one transaction.

An application nobody confirmed is **deleted after three hours**
(`JoinApplications.Sweeper`, every ten minutes). A mistyped address therefore does not
keep someone else's words around.

## Keys

| Key | Held by | Used for | At rest |
| --- | --- | --- | --- |
| receipt number (6 digits) | printed in the mail and on the page | matching one to the other; **not a secret** | plain |
| `claim` | the browser that applied (its session) | saying "yes, I got the mail", or fixing the address | sha256 |
| edit `key` | the person, in the second mail | reading and rewriting the words | sha256 |
| entry key | the person, in the welcome mail | one sign-up, within 14 days; used once | sha256 (`entry_hash`) |

`claim` and the keys are 192 random bits and travel in request bodies, never URLs
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
- `POST /api/v1/join/entry {key}` → `{valid: true}`, or 410 `entry_invalid` / `entry_used` / `entry_expired`

The greeter's side needs an `admin:read` / `admin:write` token **and** an admin account:

- `GET /api/admin/join_applications` → who is waiting and the next check day
- `GET /api/admin/join_applications/:receipt` → one, in full, with the address to write to (the list never carries it; it is erased with the words once the answer is sent)
- `POST /api/admin/join_applications/:receipt/welcome {note}`, `/decline {reason}`
  (each up to 500 characters; 502 `send_failed` if the mail did not go, and then nothing is deleted)

Statuses: 404 `join_not_found` (also: expired), 409 `join_confirmed`, 422
`validation_failed`, 429 `rate_limited`, 502 `send_failed`.

## Storage

Table `join_applications` (Postgres migration `20261107000001`; the store derives
its schema from the Ecto schema, a new table needs no migration). Tests run on
both stores.

## web-gov

`web-gov/` is a static Svelte 5 page (no server of its own). Without a token it shows
only the public window (who looks, which day). Logging in adds the greeter's tools.

Login is OAuth authorization code **with PKCE (S256)**, as a public client: no secret
is shipped to the browser. The page sends the visitor to `/oauth/authorize` on
sukhi.social (the consent page in web-next), and trades the returned code plus its
verifier at `/oauth/token`. The token stays in the tab's `sessionStorage`. A public
client cannot refresh, so when the token runs out the greeter logs in again.

Scopes `admin:read admin:write` are granted only when **both** the account is an admin
and the app is owned by an admin; otherwise the consent is refused.

### Putting web-gov up

Build settings are compile-time:

```bash
cd web-gov
VITE_API_BASE=https://sukhi.social VITE_CLIENT_ID=<client_id> pnpm build
```

1. **Register the app once** (an operator step, from the gateway's remote console;
   `owner_account_id` is an admin's id). The secret it returns is not used by web-gov:

   ```elixir
   SukhiFedi.OAuth.register_app(%{
     name: "sukhi gov",
     redirect_uris: "https://gov.sukhi.social/",
     scopes: "admin:read admin:write",
     owner_account_id: <admin id>
   })
   ```

   `redirect_uris` must match the page's address character for character (the trailing `/`).
2. Build with that `client_id` (above), and copy `dist/` to `/srv/sukhi-gov` on the box.
3. nginx: [`infra/nginx/sukhi-gov.conf`](../infra/nginx/sukhi-gov.conf). The box's 443 is a
   `stream` that routes by SNI to an inner http server on 127.0.0.1:8443, so gov is
   one more line in the stream `map` (`gov.sukhi.social 127.0.0.1:8443;`), this
   server in `conf.d/`, and the name added to the port-80 redirect. `gov.sukhi.social`
   goes through Cloudflare (proxied, Full (strict)) and reuses the Cloudflare Origin CA
   certificate that covers `*.sukhi.social`. The config lists `X25519MLKEM768` first, or
   Cloudflare gets a 525.
4. `JOIN_GREETER` and `JOIN_CHECK_DAYS` ([`ENV.md`](ENV.md)) set on the gateway.

CORS: the gateway already answers `*` with the `Authorization` header, so nothing to add.

## Not here yet

- The welcome and decline mails go out from the no-reply address, so they do not say
  "reply to this mail".
- A preview of the mail in web-gov (the server's wording is the only copy).
- `JOIN_GREETER` and `JOIN_CHECK_DAYS` move to an admin screen in step 4.
