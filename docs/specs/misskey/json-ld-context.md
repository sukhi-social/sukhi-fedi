<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: JSON-LD context

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

Misskey writes this `@context`: `https://www.w3.org/ns/activitystreams`, `https://w3id.org/security/v1`, and one inline term map. **[src]** `misc/contexts.ts`

| Term | Expands to |
| --- | --- |
| `Key` | `sec:Key` |
| `manuallyApprovesFollowers`, `sensitive`, `Hashtag`, `quoteUrl` | `as:` + the name |
| `toot` | `http://joinmastodon.org/ns#` |
| `Emoji`, `featured`, `discoverable` | `toot:` + the name |
| `schema` | `http://schema.org#` |
| `PropertyValue`, `value` | `schema:` + the name |
| `misskey` | `https://misskey-hub.net/ns#` |
| `_misskey_content`, `_misskey_quote`, `_misskey_reaction`, `_misskey_votes`, `_misskey_summary`, `_misskey_followedMessage`, `_misskey_requireSigninToViewContents`, `_misskey_makeNotesFollowersOnlyBefore`, `_misskey_makeNotesHiddenBefore`, `_misskey_license`, `isCat` | `misskey:` + the name |
| `freeText` | `misskey:freeText`, typed `schema:text` |
| `vcard` | `http://www.w3.org/2006/vcard/ns#` |

sukhi's own context defines `toot`, `misskey`, `sensitive`, `Hashtag`, `Emoji`, `_misskey_content`, `_misskey_quote`, and `quoteUrl` (at least; the list was read down to `_misskey_content`). **[sukhi]** `fedi/builders.ex:32-49`
