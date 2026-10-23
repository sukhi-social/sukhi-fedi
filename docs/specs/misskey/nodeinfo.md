<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: NodeInfo

- Kind: descriptive (what Misskey does). Source tags and how to read them: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.

### Misskey as a server **[src]** `server/NodeinfoServerService.ts`

- `GET /nodeinfo/2.1` and `GET /nodeinfo/2.0`. Content type `application/json; profile="http://nodeinfo.diaspora.software/ns/schema/2.1#"` (or `2.0#`). Cached 10 minutes.
- Discovery links: schema 2.1 and 2.0. How the wrapper object is made was **[not seen]**.
- Fields: `software` (`name` `misskey`, `version`, `homepage`, and in 2.1 `repository`), `protocols` `["activitypub"]`, `services` (`inbound` empty, `outbound` `atom1.0` and `rss2.0`), `openRegistrations`, `usage` (`users.total`, `users.activeMonth` and `activeHalfyear` always null, `localPosts`, `localComments` 0).
- `metadata`: `nodeName`, `nodeDescription`, `nodeAdmins`, `maintainer` (deprecated), `langs`, `tosUrl`, `privacyPolicyUrl`, `inquiryUrl`, `impressumUrl`, `repositoryUrl`, `feedbackUrl`, `disableRegistration`, `disableLocalTimeline`, `disableGlobalTimeline`, `emailRequiredForSignup`, `enableHcaptcha`, `enableRecaptcha`, `enableMcaptcha`, `enableTurnstile`, `enableEmail`, `enableServiceWorker`, `maxNoteTextLength`, `proxyAccountName`, `themeColor`.
- This file does not hide anything when federation is off. Any gating is elsewhere.

### Misskey as a client **[src]** `core/FetchInstanceMetadataService.ts`

- It fetches `https://<host>/.well-known/nodeinfo` as JSON. A 404 is `No nodeinfo provided`.
- It accepts only the `rel` values for schema 1.0, 2.0, and 2.1. It prefers 2.1, then 2.0, then 1.0. The order in the discovery list does not matter.
- It reads `software.name` (lowercased), `software.version`, `openRegistrations`, `metadata.maintainer.name` and `.email`.
- Display name: `metadata.nodeName`, then `metadata.name`, then the HTML `og:title`, then the web manifest name.
- Description: `metadata.nodeDescription`, then `metadata.description`, then HTML `description` and `og:description`.
- Theme colour: `metadata.themeColor`, then the HTML `theme-color` meta, then the manifest.
- It also fetches the home page HTML, `/manifest.json`, and a favicon (`/favicon.ico` by HEAD if no `<link rel="icon">`).
- A failure in one source does not stop the others. Data is refreshed at most once a day, unless forced.

### sukhi **[sukhi]** `web/nodeinfo_controller.ex`

- sukhi lists 2.0 and then 2.1 in the discovery document, and serves the same body at both. Misskey prefers 2.1 whichever comes first, so the order is fine.
- `software.name` is `sukhi-fedi`; Misskey stores it lowercased, which changes nothing.
- `metadata` is `{}`. Misskey therefore uses the HTML page and the manifest of sukhi for the display name, description, and colour. Setting `metadata.nodeName`, `nodeDescription`, and `themeColor` would give Misskey those values directly. This is a gap in sukhi, not a fault.
- `activeMonth` and `activeHalfyear` are 0 in sukhi and null in Misskey. A reader should not rely on either.
