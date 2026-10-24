<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: a descriptive specification

This is what Misskey does when it federates, written for someone who knows ActivityPub and wants their server to work with Misskey. It states facts about Misskey, read from its source. It does not say what anyone must do, and it is not about any other server.

- Subject: Misskey, `packages/backend/src` on the `develop` branch. No release tag was pinned, so the version is unknown. Forks (Sharkey, Firefish, Iceshrimp) are not covered.
- Status: Draft. Written 2026-10-23; the transport, signature, activity, object, collection, and delivery pages were checked against the raw source files on 2026-10-24. Nothing was tested against a live Misskey server.

## Where to start

Read in this order if you are building a server that talks to Misskey. The first two steps are the minimum.

**1. Be found.** Misskey looks you up by `user@host`.
[webfinger](webfinger.md) → [nodeinfo](nodeinfo.md) → [actor](actor.md) (`#Person`)

**2. Receive from Misskey.** Misskey POSTs activities to your inbox.
[transport](transport.md) (how it sends) → [signatures](signatures.md) (how to verify it) → [activities](activities.md) (what each activity means; types `#Create` ... `#Flag`) → [objects](objects.md) (the `#Note` inside)

**3. Show what Misskey sends.** Features, each on its own page:
[mfm](mfm.md) (formatted text) · [emoji](emoji.md) · [quote](quote.md) · [reactions](reactions.md) · [poll](poll.md)

**4. Send to Misskey.** What it reads and what it does with it.
[activities](activities.md) (the `#In...` types at the end) → [objects](objects.md) (`#InNote`, `#InActor`) → [signatures](signatures.md) (how to sign) → [delivery](delivery.md) (what it does when you fail)

**5. Serve what Misskey fetches.** [transport](transport.md) (`GET` routes) → [collections](collections.md)

**6. Look up a term.** [json-ld-context](json-ld-context.md), [extensions](extensions.md) (every Misskey-only term)

## Reading the pages

Every page starts with *In one paragraph*, then says what Misskey does, then lists *Things to watch* (what is easy to get wrong), and ends with *Not researched* where something is missing.

**Types.** The shape of a JSON message is written as a [CUE](https://cuelang.org) type, and the examples on the page are checked against it. You need five symbols:

| Symbol | Meaning |
| --- | --- |
| `#Name: { ... }` | a type called `Name` |
| `field: T` | the property must be present and of type `T` |
| `field?: T` | the property may be absent |
| `A \| B` | either `A` or `B` |
| `=~"^re$"`, `!=""`, `int`, `bool`, `string`, `null` | a pattern, "not empty", and the plain types |

A type with no `...` inside is **closed**: no property other than the ones listed may appear. The types for what Misskey writes are closed; they list every property it writes. The types for what Misskey reads (`#In...`) are open, because it ignores the rest. `if source != _|_ { ... }` means "when `source` is present, also require ...". A field whose name starts with an underscore is written in quotes (`"_misskey_content"`).

```cue
// A URL as it appears in these messages: absolute, http or https.
#URL: =~"^https?://[^\\s]+$"
```

**Where each fact comes from.**

| Tag | Meaning |
| --- | --- |
| **[src]** | Read in a Misskey source file; the file is named. |
| **[not seen]** | Looked for and not found in the files read. This is not proof of absence. |
| *name only* | The meaning is a guess from the name of a term; the code that uses it was not opened. |

Files read: `ActivityPubServerService`, `ApInboxService`, `ApRendererService`, `ApNoteService`, `ApPersonService`, `ApQuestionService`, `ApImageService`, `ApMentionService`, `ApAudienceService`, `ApDeliverManagerService`, `ApRequestService`, `ApMfmService`, `InboxProcessorService`, `DeliverProcessorService`, `QueueService`, `QueueProcessorService`, `UserFollowingService`, `ReactionService`, `JsonLdService`, `WellKnownServerService`, `NodeinfoServerService`, `RemoteUserResolveService`, `FetchInstanceMetadataService`, `type.ts`, `misc/contexts.ts`.

## Terms

| Term | Meaning here |
| --- | --- |
| inbox, shared inbox | an actor's inbox receives deliveries for that actor; a server's shared inbox (`/inbox`) receives them for all its users, so a sender delivers once per server |
| Public, home, followers, direct | Misskey's four visibilities; they are not properties, only a reading of `to` and `cc` ([note](note.md)) |
| local-only | a note marked by its author as not to be federated; Misskey never sends it |
| queue, job | Misskey does its slow work in a job queue; a 202 from the inbox means "queued" |
| permanent failure | a job that ends and is never retried |
| suspended, federation `none` | an admin can suspend a server or a user, and can turn federation off; Misskey then ignores or refuses |
| relay | a server that forwards public activities between servers that follow it |
| Tombstone | the stand-in object an `ActivityStreams` `Delete` carries for a note that no longer exists |
| ld-signature | the `RsaSignature2017` Linked-Data signature inside the activity, older than HTTP signatures ([signatures](signatures.md)) |
| MFM | Misskey Flavored Markdown ([mfm](mfm.md)) |

## Pages

| File | Feature |
| --- | --- |
| [transport.md](transport.md) | inbox routes, body limit, content types, `GET` routes |
| [signatures.md](signatures.md) | HTTP signatures: checking and signing |
| [webfinger.md](webfinger.md) | WebFinger and host-meta, as server and as client |
| [nodeinfo.md](nodeinfo.md) | NodeInfo, as server and as client |
| [json-ld-context.md](json-ld-context.md) | the `@context` Misskey writes |
| [actor.md](actor.md) | the Person document |
| [note.md](note.md) | the Note, sent and received; visibility |
| [mfm.md](mfm.md) | MFM: when the source is sent, and the HTML it makes |
| [emoji.md](emoji.md) | custom emoji tags |
| [quote.md](quote.md) | quote posts |
| [reactions.md](reactions.md) | emoji reactions |
| [poll.md](poll.md) | polls and votes |
| [activities.md](activities.md) | every activity Misskey sends and how it handles each one it receives |
| [objects.md](objects.md) | the Note, Person, and the objects inside activities |
| [collections.md](collections.md) | outbox, followers, following, featured |
| [delivery.md](delivery.md) | who gets an activity, retries, suspension |
| [extensions.md](extensions.md) | every Misskey-only term |

## Not researched

- `WebfingerService` of Misskey (the request URL, the host-meta fallback, `subject` checks, redirects).
- The wrapper object of `/.well-known/nodeinfo` in Misskey.
- Whether `@peertube/http-signature` checks the `Date` header, and the allowed difference.
- Key refetch after a failed signature.
- Misskey's authorized-fetch option, if any.
- Media (`attachment`) limits.
- Behaviour of forks (Sharkey, Firefish, Iceshrimp).
- Any behaviour that changed on `develop` after the dates above.
- The grammar of `mfm-js`.
