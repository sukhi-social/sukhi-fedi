# Feedback inbox

A person using the app can tell the operator something: what broke, what
confused them, what they wished for. It lands in a table the operator
reads. Nothing is sent to an outside service.

## Sending

`POST /api/v1/feedback`, JSON:

```json
{ "body": "…", "screen": "timeline", "lang": "ja", "version": "1.2.3" }
```

| field | rule |
|---|---|
| `body` | required; trimmed; 1..2000 characters |
| `screen` | optional; up to 64 |
| `lang` | optional; up to 16 |
| `version` | optional; up to 64 |

Answers: `202 {"id": "<opaque>"}`; `422 {"error": "validation_failed",
"details": {...}}`; `429 {"error": "rate_limited"}` with `retry-after`.

Anonymous is allowed. A valid bearer (or the first-party session cookie)
adds the sender's account id; with none, it is `null`. A bearer that is
sent but invalid gets the router's usual `401`, like every other open
route that reads the viewer.

## What is stored

`feedback_items`: the four fields above, `account_id` (nullable), and
`created_at`, plus `handled_at` / `handled_by_id` once the operator marks
it done. **No IP address, no user agent, no session, nothing else.** The
rate limiter sees the peer address in memory only; it is never written
down. If the sender's account is deleted the item stays and `account_id`
becomes `null`.

## Where each rule lives (one place each)

| rule | place |
|---|---|
| length caps, trimming, required | `SukhiFedi.Schema.FeedbackItem.changeset/2` |
| rate limit (5 per 15 min per peer) | `post "/api/v1/feedback"` in `SukhiFedi.Web.Router` (listed on `@edge` in `web_surface_test.exs`) |
| who may read | `admin:read` scope + `AdminAuth.require_admin/1` in `SukhiApi.Capabilities.Feedback` |

## Reading (operators only)

- `GET /api/v1/admin/feedback?page=&per_page=&handled=true|false` —
  newest first, `{items, pagination}` like the other admin lists. Needs
  the `admin:read` scope **and** an `is_admin` account; anyone else gets
  `401`/`403`.
- `POST /api/v1/admin/feedback/:id/handled` — mark an item handled
  (`admin:write`). Idempotent.

There is no public or per-user read. The sender cannot read back what
they sent.

## Retention

Items are kept until the operator removes them. Handled items can be
purged with `SukhiFedi.Feedback.purge_handled_before/1` (e.g. from a
remote console: `SukhiFedi.Feedback.purge_handled_before(DateTime.add(DateTime.utc_now(), -180 * 86_400))`).
It never touches unhandled items. It is not scheduled; running it is an
operator decision.
