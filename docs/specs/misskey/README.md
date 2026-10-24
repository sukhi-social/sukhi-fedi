<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: a descriptive specification

One file per feature. Each file states what Misskey does, as read from its source. None of it says what anyone must do, and none of it is about any other server. (How sukhi meets these behaviours is in [../../misskey-interop-sukhi.md](../../misskey-interop-sukhi.md).)

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
| [mfm.md](mfm.md) | MFM: when the source is sent, and the HTML it makes |
| [emoji.md](emoji.md) | custom emoji tags |
| [quote.md](quote.md) | quote posts |
| [reactions.md](reactions.md) | emoji reactions |
| [poll.md](poll.md) | polls and votes |
| [inbox-activities.md](inbox-activities.md) | the activity types the inbox accepts |
| [collections.md](collections.md) | outbox, followers, following, featured |
| [delivery.md](delivery.md) | retries and failure handling |
| [extensions.md](extensions.md) | every Misskey-only term |

Each page begins with a one-paragraph summary.

Every statement is tagged with where it comes from.

| Tag | Meaning |
| --- | --- |
| **[src]** | Read in a Misskey source file on 2026-10-23. The file is named. |
| **[study]** | Taken from the delivery study in the project files (`federation/push-federation-ste.md`, source read 2026-10-22). |
| **[not seen]** | Looked for and not found in the files read. This is not proof of absence. |

The Misskey files were read through a summarising tool, not line by line by a person. A statement marked **[src]** should be checked against the file before it is relied on. Nothing here was tested against a live Misskey server. Files read: `ActivityPubServerService`, `ApInboxService`, `ApRendererService`, `ApNoteService`, `InboxProcessorService`, `WellKnownServerService`, `NodeinfoServerService`, `RemoteUserResolveService`, `FetchInstanceMetadataService`, `type.ts`, `misc/contexts.ts`.

## Terms used by the types

The pages write the shape of each JSON message as a [CUE](https://cuelang.org) type, and check the examples against it (`make check-specs`; see [check](../check/README.md)). One helper is shared:

```cue
// A URL as it appears in these messages: absolute, http or https.
#URL: =~"^https?://[^\\s]+$"
```

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
