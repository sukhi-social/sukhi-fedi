# Mastodon REST API — supported surface

What this is, what it deviates on, and what to expect when you talk
to sukhi-fedi with a Mastodon client. Endpoint coverage tracks the
capabilities under `api/lib/sukhi_api/capabilities/`. Discovery is
the source of truth: `mix run --eval 'IO.inspect SukhiApi.Registry.routes()'`
inside `api/` prints the live route table.

## Conventions and global deviations

- **IDs.** Internally bigserial; rendered as decimal strings via
  `SukhiApi.Views.Id.encode/1`. Wire-format compatible with Mastodon's
  string ids; lexical ordering is **not** chronological. Snowflake
  migration is deferred (see OPEN_QUESTIONS Q6).
- **Pagination.** Standard Mastodon `max_id` / `since_id` / `min_id` /
  `limit`. Index endpoints emit `Link: <url>; rel="prev|next"` headers.
- **OAuth.** PKCE + password grant + client_credentials. Scopes are
  enforced server-side; unknown scopes are not rejected at app
  registration (a forward-compat choice — addons declare their own).
- **Bearer cache.** Verified tokens are positive-cached in
  `:sukhi_api` for 60 s (see `SukhiApi.TokenCache`); revocation has
  up to 60 s of staleness.
- **Per-token rate limit.** 300 req / 5 min (Mastodon's published
  authenticated REST default). Returns `429` with `Retry-After`.
- **Times.** Always ISO-8601 UTC.

## OAuth

| Method | Path                                | Notes |
| ------ | ----------------------------------- | ----- |
| POST   | `/api/v1/apps`                      | Returns `client_id` / `client_secret`. Scopes default to `read`. |
| POST   | `/api/v1/apps/verify_credentials`   | Echoes the app row for the bearer's client. |
| GET    | `/oauth/authorize`                  | HTML login → consent. |
| POST   | `/oauth/authorize`                  | Issues an authorization code. |
| POST   | `/oauth/token`                      | `authorization_code`, `password`, `client_credentials`, `refresh_token`. |
| POST   | `/oauth/revoke`                     | RFC 7009; idempotent. |

## Accounts

| Method | Path                                                  | Scope |
| ------ | ----------------------------------------------------- | ----- |
| GET    | `/api/v1/accounts/verify_credentials`                 | read |
| PATCH  | `/api/v1/accounts/update_credentials`                 | write:accounts |
| GET    | `/api/v1/accounts/:id`                                | (public) |
| GET    | `/api/v1/accounts/:id/{followers,following,statuses}` | (public) |
| GET    | `/api/v1/accounts/lookup?acct=user@host&resolve=1`    | Fans out via WebFinger + ActorFetcher on miss. |
| GET    | `/api/v1/accounts/search`                             | Local handles + remote with `resolve=true`. |

**Deviation.** No `featured_tags` block on the account view (no
`featured_tags` table). The `locked` field is always `false`; we
don't have an account-level lock column yet.

## Statuses

| Method | Path | Scope |
| ------ | ---- | ----- |
| POST   | `/api/v1/statuses` | write:statuses |
| GET    | `/api/v1/statuses/:id` | (visibility-checked) |
| DELETE | `/api/v1/statuses/:id` | write:statuses |
| GET    | `/api/v1/statuses/:id/{reblogged_by,favourited_by}` | (public) |
| GET    | `/api/v1/statuses/:id/context` | Thread; remote replies require resolution first. |

`POST /api/v1/statuses` accepts `status`, `media_ids[]`,
`in_reply_to_id` (numeric local id **or** http(s) URI of a remote
note — the latter auto-fetches + mirrors via
`Federation.NoteFetcher`), `spoiler_text`, `visibility`. Polls (via
`poll[options][]`, `poll[expires_in]`, `poll[multiple]`) are
**not yet** wired into `create_status/2` — only standalone Poll
read + vote endpoints are live (see Polls below).

**Sukhi extension: `delivery`.** A Status the viewer wrote themself,
within the last 2 days, carries `delivery`: `"delivering"` (still on its
way out), `"delivered"` (nothing is waiting), or `"delayed"` (a send is
being retried or was given up on). For anyone else's post it is `null`.
`DELETE /api/v1/statuses/:id` returns it for the Delete's own trip. It is
three words on purpose: no server names and no counts are in the API, the
web UI, or anything else the author sees (the admin pages are unchanged).
Read from `outbox` + `oban_jobs` by `SukhiFedi.DeliveryStatus`; Pull
Federation posts count as delivered once logged.

**Deviation.** `visibility: "direct"` rejected with
`:direct_visibility_not_supported`. Mention extraction + addressing
land with DM work (OPEN_QUESTIONS Q4).

## Interactions

| Method | Path | Scope |
| ------ | ---- | ----- |
| POST   | `/api/v1/statuses/:id/favourite` | write:favourites |
| POST   | `/api/v1/statuses/:id/unfavourite` | write:favourites |
| POST   | `/api/v1/statuses/:id/reblog` | write:statuses |
| POST   | `/api/v1/statuses/:id/unreblog` | write:statuses |
| POST   | `/api/v1/statuses/:id/{bookmark,unbookmark}` | write:bookmarks |
| POST   | `/api/v1/statuses/:id/{pin,unpin}` | write:accounts |
| GET    | `/api/v1/bookmarks` | read:bookmarks |
| GET    | `/api/v1/favourites` | read:favourites |

Local-to-local interactions emit Mastodon-shaped notifications for
the note author; remote interactions arrive via the inbox path and
notify the same way.

## Follows

| Method | Path | Scope |
| ------ | ---- | ----- |
| POST   | `/api/v1/accounts/:id/{follow,unfollow}` | write:follows |
| GET    | `/api/v1/follow_requests` | read:follows |
| GET    | `/api/v1/accounts/relationships?id[]=…` | read:follows |

Local-target follows land as `accepted` synchronously and skip the
outbox; remote-target follows ride the `sns.outbox.follow.requested`
path and flip to `accepted` when the remote's `Accept(Follow)`
returns through the inbox.

## Timelines

| Method | Path | Scope |
| ------ | ---- | ----- |
| GET    | `/api/v1/timelines/home` | read:statuses |
| GET    | `/api/v1/timelines/public?local=1&only_media=1` | (public) |
| GET    | `/api/v1/timelines/tag/:hashtag?local=1` | (public) |
| GET    | `/api/v1/timelines/list/:list_id` | read:lists |

Hashtags are lower-cased; the tag timeline matches case-insensitively.
Public TL defaults to `local=true`.

## Notifications

| Method | Path | Scope |
| ------ | ---- | ----- |
| GET    | `/api/v1/notifications?types[]=…&exclude_types[]=…` | read:notifications |
| GET    | `/api/v1/notifications/:id` | read:notifications |
| POST   | `/api/v1/notifications/clear` | write:notifications |
| POST   | `/api/v1/notifications/:id/dismiss` | write:notifications |

Types emitted today: `follow`, `favourite`, `reblog`. `mention`,
`poll`, `update`, `status`, `follow_request` are valid columns but
no writer hits them yet.

## Lists

| Method | Path | Scope |
| ------ | ---- | ----- |
| GET    | `/api/v1/lists` | read:lists |
| POST   | `/api/v1/lists` | write:lists |
| GET    | `/api/v1/lists/:id` | read:lists |
| PUT    | `/api/v1/lists/:id` | write:lists |
| DELETE | `/api/v1/lists/:id` | write:lists |
| GET    | `/api/v1/lists/:id/accounts` | read:lists |
| POST   | `/api/v1/lists/:id/accounts` | write:lists |
| DELETE | `/api/v1/lists/:id/accounts` | write:lists |
| GET    | `/api/v1/timelines/list/:list_id` | read:lists |

Members must be accounts the owner already follows in `accepted`
state. `account_ids[]` not satisfying that constraint are silently
skipped on POST (Mastodon clients re-list immediately afterwards).

## Polls

| Method | Path | Scope |
| ------ | ---- | ----- |
| GET    | `/api/v1/polls/:id` | read:statuses |
| POST   | `/api/v1/polls/:id/votes` | write:statuses |

`choices[]` accepts 0-based option indices (Mastodon's wire form)
or absolute `PollOption` PKs. The response is the same poll object
re-rendered with updated tallies + `voted: true`.

## Media

| Method | Path | Scope |
| ------ | ---- | ----- |
| POST   | `/api/v2/media` | write:media |
| GET    | `/api/v1/media/:id` | write:media |
| PUT    | `/api/v1/media/:id` | write:media |

Inline upload is capped at 8 MiB (distributed Erlang transport
limit). >8 MiB uploads will move to a presigned-PUT flow; design
parked in OPEN_QUESTIONS Q5.

## Instance / discovery

| Method | Path | Notes |
| ------ | ---- | ----- |
| GET    | `/api/v1/instance` | Mastodon v1 instance shape. |
| GET    | `/api/v2/instance` | v2 (subset). |
| GET    | `/.well-known/webfinger` | `acct:` and `?resource=` URI form both accepted. |
| GET    | `/.well-known/nodeinfo` + `/nodeinfo/2.1` | Mastodon-flavoured. |

## Gaps

Tracked in [`TODO.md`](../TODO.md) and [`OPEN_QUESTIONS.md`](../OPEN_QUESTIONS.md):

- **Streaming WebSocket** — `/api/v1/streaming/*` (Q2).
- **Search** — `/api/v2/search` (Q1).
- **Web Push** — `/api/v1/push/subscription`.
- **Moderation** (`/api/v1/{blocks,mutes,reports,domain_blocks}`, `/api/admin/*`) — capability layer present, REST surface missing (Q9).
- **Scheduled statuses, Conversations, Trends, Suggestions, Directory** — design pending.
- **Misskey native API** — a separate surface (Q3); shares the underlying contexts but ships behind `addon: :misskey_api`.

## Curl walkthrough

`scripts/smoke.sh` runs OAuth → verify_credentials → status → home
TL → media upload → status with media, against a running instance.
Set `BASE_URL` to point it elsewhere than the default
`http://localhost:4000`.
