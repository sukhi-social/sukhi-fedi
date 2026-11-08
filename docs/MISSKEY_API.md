# Misskey API — planned surface

> **Status: not implemented.** This is a design map, not a contract.
> No Misskey REST routes exist yet — the `api/` plugin node carries only
> `mastodon_*` capabilities. This document records the intended shape
> so the work can be picked up without re-deciding it. See
> [`TODO.md`](../TODO.md) for the punch-list and
> [`OPEN_QUESTIONS.md`](../OPEN_QUESTIONS.md) Q3 for the addon-granularity
> decision.

This is about the **client API** — letting Misskey clients (MissCat,
Aria, …) talk to sukhi-fedi over `/api/i`, `/api/notes/*`, etc. It is
separate from **federation interop** (speaking ActivityPub with Misskey
*servers*), which is largely live: follows, notes, boosts, and custom
emoji reactions (`EmojiReact`) already round-trip. See
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md) for the federation side.

## Why this is mostly a view layer

The hard part — storage and domain logic — already exists and is
shared with the Mastodon surface:

- `SukhiFedi.Notes` / `SukhiFedi.Timelines` — note CRUD and timelines.
- `SukhiFedi.Schema.Reaction` — arbitrary emoji strings, so Misskey
  custom reactions need no schema change.
- the `bookmarks` table — a private, local-only note save. Misskey's
  お気に入り (`/i/favorites`) is the same primitive under a different
  name; see the moduledoc on `SukhiFedi.Schema.Bookmark`.

So a Misskey client API is mostly a **new view layer** plus a session
auth shim — not new persistence. Per OPEN_QUESTIONS Q3 it lands as a
single `:misskey_api` addon bundling capabilities namespaced
`misskey.notes.create`, `misskey.users.show`, … toggled by one flag.

## Planned surface

Discovery stays the source of truth once routes exist:
`mix run --eval 'IO.inspect SukhiApi.Registry.routes()'` inside `api/`.

### Auth

| Method | Path | Notes |
| ------ | ---- | ----- |
| POST | `/api/auth/session/generate` | Mint a session token + approval URL. |
| POST | `/api/auth/session/userkey` | Exchange an approved session for a user key. |

**Open question.** Misskey's session keys map onto the existing
`oauth_access_tokens` table, but Misskey's `permission: ["read:account",
…]` list has to be translated into our scope strings. Design this
before writing the auth capability (OPEN_QUESTIONS Q3).

### Self

| Method | Path | Notes |
| ------ | ---- | ----- |
| POST | `/api/i` | Current user — mirrors Mastodon `verify_credentials`. |
| POST | `/api/i/update` | Profile update — mirrors `update_credentials`. |
| POST | `/api/i/favorites` | The viewer's bookmarks, in Misskey shape. |

### Users

| Method | Path | Notes |
| ------ | ---- | ----- |
| POST | `/api/users/show` | Account by id or `@user@host`. |
| POST | `/api/users/notes` | A user's notes. |
| POST | `/api/users/{followers,following}` | Relationship lists. |
| POST | `/api/following/{create,delete}` | Follow / unfollow. |

### Notes

| Method | Path | Notes |
| ------ | ---- | ----- |
| POST | `/api/notes/create` | Reuses `Notes.create_status/2`. |
| POST | `/api/notes/delete` | |
| POST | `/api/notes/show` | |
| POST | `/api/notes/timeline` | Home — reuses `Timelines.home/2`. |
| POST | `/api/notes/{local,global,hybrid}-timeline` | Public variants. |
| POST | `/api/notes/{replies,mentions}` | Thread + mention feeds. |
| POST | `/api/notes/reactions/create` | Custom emoji reaction → `Reaction` row. |
| POST | `/api/notes/reactions/delete` | |
| POST | `/api/notes/favorites/{create,delete}` | → the `bookmarks` table. |

## Expected deviations

- **MFM.** Misskey Flavored Markdown source is not stored (the `mfm`
  column was dropped). Notes round-trip as HTML `content`; MFM-only
  markup will not survive. Full fidelity needs the source column back.
- **Quote notes.** No quote storage today (`quote_of_ap_id` was
  retired). `/api/notes/create` with `renoteId` + text would need the
  column reinstated first.
- **IDs.** Internally bigserial, rendered as decimal strings — the
  same as the Mastodon surface. Misskey clients expecting aid/aidx
  ordering may see non-chronological ids.
