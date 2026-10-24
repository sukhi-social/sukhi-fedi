<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Meeting Misskey: what sukhi does, and the gaps

This is a working note, not a specification. [specs/misskey/](specs/misskey/README.md) says what Misskey does and nothing about sukhi. This note sets sukhi's code against it. The Misskey facts are from `develop`, read on 2026-10-23 and not tested on a live server. The sukhi facts name the file they come from. Rules that bind sukhi are in the numbered specifications ([specs/](specs/README.md)).

## What sukhi relies on

| Need | Misskey behaviour (page) | sukhi action | Where |
| --- | --- | --- | --- |
| Accept our signature | cavage, with digest and host signed ([signatures](specs/misskey/signatures.md)) | falls back to cavage on 400/401 | [sukhi-0001](specs/sukhi-0001-signature-fallback.md) |
| Show our quote | reads `_misskey_quote`, `quoteUrl` ([quote](specs/misskey/quote.md)) | sends both and the tag `Link` | [sukhi-0003](specs/sukhi-0003-legacy-quote-profile.md) |
| Show our reaction | reads `_misskey_reaction`, `content`, `name` ([reactions](specs/misskey/reactions.md)) | sends `Like` with `content` | `fedi/builders.ex:206-227` |
| Show our formatting | reads `_misskey_content`, `source` ([mfm](specs/misskey/mfm.md)) | reads and keeps MFM; sends `_misskey_content` | `notes/create.ex` |
| Find our account | WebFinger: first `self` link, its host must equal the acct host; name lowercased ([webfinger](specs/misskey/webfinger.md)) | `self` first; case handling of the account lookup unverified | `web/webfinger_controller.ex` |
| Show our server | NodeInfo 2.1 then 2.0; reads `metadata.nodeName`, `nodeDescription`, `themeColor` ([nodeinfo](specs/misskey/nodeinfo.md)) | `metadata` is empty; Misskey falls back to the HTML page | `web/nodeinfo_controller.ex` |
| Accept our activity ids | `activity.id` host must equal signer host | ids are on our domain | `fedi/builders.ex` |
| Keep our edits | applies `Update` of actors and `Question` only ([activities](specs/misskey/activities.md)) | sends `Update(Note)`; probably not applied | gap |
| Keep our public notes public | accepts three spellings of Public | sends the full IRI | `audience.ex` |
| Count our poll votes | counts a `Note` with matching `name` ([poll](specs/misskey/poll.md)) | sends that shape | `builders.ex` `vote/1` |

## Page by page

### Transport

- A body over 64 KB is refused by Misskey, with a status that was not read. sukhi retries a refused delivery, but the same body is refused again.
- The content type sukhi puts on its deliveries was not re-read.

### Signatures

- No RFC 9421 at Misskey: a sender that signs only with RFC 9421 is refused. sukhi falls back to cavage on 400 or 401 ([sukhi-0001](specs/sukhi-0001-signature-fallback.md)).
- Key owner must equal `actor`: matches [sukhi-0004](specs/sukhi-0004-signer-binding.md) on the receiving side. sukhi signs as the actor it names.
- Every `id` sukhi puts on an activity is on its own domain, so the `activity.id` host rule holds (`fedi/builders.ex`).
- A FEP-8b32 proof adds nothing for Misskey. The HTTP signature carries the trust.
- Misskey uses sukhi's Linked-Data signature only when the HTTP signature fails.
- Permanent failures are silent: the route already answered 202, so sukhi never learns of them.

### WebFinger (`web/webfinger_controller.ex`)

| Misskey asks | sukhi answers |
| --- | --- |
| `acct:name@domain` for a local account | 200 JRD: `subject`, `aliases` (the actor URL), `self`, `profile-page` |
| a name on another host | 404 (Misskey itself answers 422) |
| an actor URL under `/users/<name>` | the same JRD |
| no `resource` | 400 |
| `host-meta` | XRD with the `lrdd` template |

- The `self` link is first, which is the one Misskey uses.
- Misskey lowercases the name before asking. sukhi passes it to `Accounts.get_account_by_username/1` as it is. Whether that lookup ignores case was not seen. If it does not, an account with capitals in its name cannot be found by Misskey. Needs a test.
- sukhi caches each answer for 600 seconds.

### NodeInfo (`web/nodeinfo_controller.ex`)

- Discovery lists 2.0, then 2.1, and the same body is served at both. Misskey prefers 2.1 whatever the order.
- `software.name` is `sukhi-fedi`.
- `metadata` is `{}`, so Misskey uses sukhi's home page and manifest for name, description, and colour. A gap, not a fault.
- `activeMonth` and `activeHalfyear` are 0. Misskey sends null. A reader should rely on neither.

### JSON-LD context (`fedi/builders.ex:32-49`)

sukhi's context has the two standard contexts, the data-integrity context (FEP-8b32), `https://gotosocial.org/ns`, and a term map that defines at least `toot`, `misskey`, `sensitive`, `Hashtag`, `Emoji`, `_misskey_content`, `_misskey_quote`, and `quoteUrl`. A term missing from the context is dropped when the document is expanded, and sukhi's Linked-Data signature expands it, so such a term would not be covered by the signature. That is why sukhi defines every term it injects.

### Actor

sukhi tells that an actor is from the Misskey family when its `@context` has an object with a `misskey` key (`federation/remote_accounts.ex`, `misskey_family?/1`). It then asks Misskey's own API for avatar decorations. A fork that omits the term would not be found. sukhi does not use `isCat` or the other `_misskey_*` actor properties.

### Note

sukhi's note ids are on its own domain, so Misskey's same-host rule holds. A reply from sukhi to a Misskey note that Misskey cannot find fails on the Misskey side.

### Emoji

Actors and notes carry `Emoji` tags built from the saved emoji; rows without a URL are dropped (`shared/.../actor_json.ex`, `fedi/builders.ex`). A reaction adds one `Emoji` tag with the icon URL. The web client replaces `:code:` with the image (`renderEmojis`).

### Quote (`fedi/builders.ex:347-364`)

sends all three forms ([sukhi-0003](specs/sukhi-0003-legacy-quote-profile.md)). It reads all of them on receipt, including a tag `Link` and `quoteUri` (`ap/instructions/extract.ex`). sukhi keeps sending the two Misskey reads until Misskey also reads `quote` (FEP-044f).

### Reactions (`fedi/builders.ex:206-227`)

sukhi sends `Like` with `content` and, for custom emoji, an `Emoji` tag. It does not set `_misskey_reaction`, which Misskey does not need. The choice of `Like` is made for other servers: Mastodon reads it as a plain like, and Pleroma quarantines `EmojiReact` (`FEDERATION.md` §10).

### Polls (`fedi/builders.ex`, `vote/1`)

A vote is a `Create` of a `Note` with `name`, `inReplyTo`, and `to` set to the poll's author; no `content`, no `cc`. Not researched: whether sukhi reads `_misskey_votes`.

### Inbox activities

sukhi sends `Update(Note)` on edit (`outbox/consumer.ex`). Misskey applies `Update` only to actors and `Question`, so an edit is probably not applied there. Not tested.

### Collections

sukhi serves the featured collection at `/users/:name/featured` (`web/router.ex:306`). Misskey's is `/users/:user/collections/featured`. A reader that follows the `featured` property is unaffected.

### Delivery

sukhi retries for about 20 minutes (calculated). Misskey retries for about 1.3 days. A short outage at Misskey can lose a delivery from sukhi.

### MFM

Receiving (`ap/instructions/extract.ex`, `mirror.ex`, `dms.ex`, `schema/note.ex`):
- `Extract.extract_mfm/1` takes `_misskey_content` if it is a non-empty string, otherwise `source.content`. It does not check `source.mediaType`.
- The text is stored in `notes.mfm` for notes, mirrored notes, and DMs, and extracted again on an edit.
- The Mastodon-compatible API passes it through as an extra key `mfm`.
- The web client shows `mfm` through `renderMfm` (`web/src/lib/mfm.ts`) when present, and `content` otherwise.
- `renderMfm` escapes the whole source first, then applies a static subset. Kept: fenced code, `<center>`, quote lines, inline code, `<small>`, `<b>`, `<i>`, `<s>`, `**`, `__`, `*`, `_`, `~~`, `[label](http(s) url)`, bare URLs, mentions, hashtags, emoji. Every `$[name args content]` is replaced by its content, so motion and decoration are dropped on purpose (calm UX). Not handled: `<plain>`, `search`, math, and the meaning of any `$[...]`.

Sending (`notes/create.ex`, `fedi/builders.ex` `inject_misskey_content`):
- Every note carries `_misskey_content`, the author's raw text. `content` is the HTML rendering (`Note.html`). sukhi does not send `source`.
- Misskey reads that text as MFM, so `**x**`, `<center>`, or `$[spin x]` written by a sukhi user shows as bold, centred, or spinning. Markdown that MFM does not know (headings, lists) shows as plain text.
- Sending the source for plain text is harmless but unneeded; Misskey would leave it out.

Suggestions (not statements about Misskey):
1. Check `source.mediaType` before using `source.content`, so a non-MFM `source` is not taken as MFM.
2. Keep dropping motion functions. Add `ruby` and `unixtime` only if they can be done without animation.
3. Add `source` with `mediaType: "text/x.misskeymarkdown"` on send. Optionally omit both properties for text with only the six plain node types.
4. Never put the source in a page unescaped. Keep the escape-first order.

### Extensions: what sukhi does with each Misskey-only term

| Term | sukhi | Handling |
| --- | --- | --- |
| `_misskey_content` | read and stored; sent on every note | keep both directions |
| `source` (`text/x.misskeymarkdown`) | read (media type not checked); not sent | check the media type; add on send |
| `_misskey_quote`, `quoteUrl` | read and sent | keep until [sukhi-0003](specs/sukhi-0003-legacy-quote-profile.md) ends them |
| `_misskey_reaction` | not sent; read not seen | read it first, then `content`, as Misskey does |
| `_misskey_votes` | not seen | read it if poll results from Misskey are to be shown |
| `sensitive` | read and sent | keep |
| `isCat`, `_misskey_summary`, `_misskey_followedMessage`, `_misskey_requireSigninToViewContents`, `_misskey_makeNotesFollowersOnlyBefore`, `_misskey_makeNotesHiddenBefore`, `vcard:bday`, `vcard:Address`, `freeText`, `_misskey_license` | not used | ignore (`_misskey_summary`: read like `_misskey_content` if profile MFM is wanted) |
| `featured`, `discoverable` | sent | keep |
| Avatar decorations (Misskey API `POST /api/users/show`) | read by a background job only for actors whose `@context` has a `misskey` term; stored; drawn over the icon; the web client uses `/proxy/deco/:id/:n` so the viewer's address does not reach the origin; silent on failure (`federation/misskey_decorations.ex`, `federation/remote_accounts.ex`) | keep: best effort, depends on a non-standard API |
| Misskey client API | a plan only (`docs/MISSKEY_API.md`) | none |

Rule of thumb for any extension:
1. Reading: take it when present, and fall back to the standard property when not.
2. Showing: treat the value as untrusted text. Escape first.
3. Writing: send it only if Misskey reads it and the standard property is also correct. Never make the standard property depend on it.
4. Misskey ignores FEP-8b32 proofs and checks the HTTP signature, so extension terms do not need to be covered by a proof.
