<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey interoperability: a descriptive specification

One file per feature. Each file states what Misskey does, as read from its source, and then what sukhi does. None of it says what anyone must do. The rules that bind sukhi are in the numbered specifications ([../README.md](../README.md)).

- Subject: Misskey, `packages/backend/src` on the `develop` branch, read on 2026-10-23. No release tag was pinned, so the version is unknown. Forks (Sharkey, Firefish, Iceshrimp) are not covered.
- Status: Draft.

## Features

| File | Feature |
| --- | --- |
| [transport.md](transport.md) | inbox routes, body limit, content types |
| [signatures.md](signatures.md) | HTTP signature rules and the queue checks |
| [webfinger.md](webfinger.md) | WebFinger and host-meta, as server and as client |
| [nodeinfo.md](nodeinfo.md) | NodeInfo, as server and as client |
| [json-ld-context.md](json-ld-context.md) | the `@context` Misskey writes |
| [actor.md](actor.md) | the Person document |
| [note.md](note.md) | the Note, sent and received |
| [mfm.md](mfm.md) | MFM: when the source is sent, the HTML, and how sukhi supports it |
| [emoji.md](emoji.md) | custom emoji tags |
| [quote.md](quote.md) | quote posts |
| [reactions.md](reactions.md) | emoji reactions |
| [poll.md](poll.md) | polls and votes |
| [inbox-activities.md](inbox-activities.md) | the activity types the inbox accepts |
| [collections.md](collections.md) | outbox, followers, following, featured |
| [delivery.md](delivery.md) | retries and failure handling |
| [extensions.md](extensions.md) | every Misskey-only term and how to support it |

Each page begins with a one-paragraph summary. Where a page is about a JSON shape, it prints the JSON Schema, with example messages checked against it (`make check-specs`; see [schemas](../schemas/README.md)).

Every statement is tagged with where it comes from.

| Tag | Meaning |
| --- | --- |
| **[src]** | Read in a Misskey source file on 2026-10-23. The file is named. |
| **[study]** | Taken from the delivery study in the project files (`federation/push-federation-ste.md`, source read 2026-10-22). |
| **[sukhi]** | Read in the sukhi code, with the file. |
| **[not seen]** | Looked for and not found in the files read. This is not proof of absence. |

The Misskey files were read through a summarising tool, not line by line by a person. A statement marked **[src]** should be checked against the file before it is relied on. Nothing here was tested against a live Misskey server. Files read: `ActivityPubServerService`, `ApInboxService`, `ApRendererService`, `ApNoteService`, `InboxProcessorService`, `WellKnownServerService`, `NodeinfoServerService`, `RemoteUserResolveService`, `FetchInstanceMetadataService`, `type.ts`, `misc/contexts.ts`.

## What sukhi relies on, in one table

| Need | Misskey behaviour | sukhi action | Where |
| --- | --- | --- | --- |
| Accept our signature | cavage, with digest and host signed | falls back to cavage on 400/401 | [sukhi-0001](../sukhi-0001-signature-fallback.md) |
| Show our quote | reads `_misskey_quote`, `quoteUrl` | sends both and the tag `Link` | [sukhi-0003](../sukhi-0003-legacy-quote-profile.md) |
| Show our reaction | reads `_misskey_reaction`, `content`, `name` | sends `Like` with `content` | [reactions.md](reactions.md) |
| Show our formatting | reads `_misskey_content`, `source` | reads and keeps MFM; sends `_misskey_content` | [mfm.md](mfm.md) |
| Find our account | WebFinger `self` link (first one), host of its URI must equal the acct host; name lowercased | `self` first; account lookup case-handling unverified | [webfinger.md](webfinger.md) |
| Show our server | NodeInfo 2.1 then 2.0; reads `metadata.nodeName`, `nodeDescription`, `themeColor` | `metadata` empty; Misskey falls back to HTML | [nodeinfo.md](nodeinfo.md) |
| Accept our activity ids | `activity.id` host must equal signer host | ids are on our domain | [signatures.md](signatures.md) |
| Keep our edits | applies `Update` of actors and `Question` only | sends `Update(Note)`; likely not applied | gap |
| Keep our public notes public | accepts three spellings of Public | sends the full IRI | `audience.ex` |
| Count our poll votes | counts a `Note` with matching `name` | sends that shape | `builders.ex` |

## Not researched

- `WebfingerService` of Misskey (the request URL, the host-meta fallback, `subject` checks, redirects).
- The wrapper object of `/.well-known/nodeinfo` in Misskey.
- Whether `@peertube/http-signature` checks the `Date` header, and the allowed difference.
- Key refetch after a failed signature (not in the processor file).
- Misskey's authorized-fetch option, if any.
- The `Accept`/`Reject` side for follow requests of locked accounts.
- Media (`attachment`) limits.
- Behaviour of forks (Sharkey, Firefish, Iceshrimp).
- Any behaviour that changed on `develop` after 2026-10-23.
- The grammar of `mfm-js` and the cases where Misskey adds extra HTML to a note.
