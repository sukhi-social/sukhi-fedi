<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: NodeInfo

- Kind: descriptive (what Misskey does), then what sukhi does. Tags (**[src]**, **[study]**, **[sukhi]**, **[not seen]**) and terms: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `NodeInfoMetadata`, defined below

## In one paragraph

NodeInfo is a small public document that says what software a server runs. Misskey publishes one, and reads other servers'. When it reads sukhi's, it takes the display name, description, and colour from `metadata` if they are there, and from sukhi's web page otherwise. sukhi's `metadata` is empty today, so Misskey falls back to the page.

## Misskey as a server **[src]** `server/NodeinfoServerService.ts`

- Routes `GET /nodeinfo/2.1` and `GET /nodeinfo/2.0`. Content type `application/json; profile="http://nodeinfo.diaspora.software/ns/schema/2.1#"` (`2.0#` for 2.0). Cached for 10 minutes.
- The discovery links name schema 2.1 and 2.0. How they are wrapped in the discovery document was **[not seen]**.
- Fields: `software` (`name` is `misskey`; `version`; `homepage`; `repository` in 2.1), `protocols` is `["activitypub"]`, `services` (`inbound` empty; `outbound` `atom1.0` and `rss2.0`), `openRegistrations`, `usage` (`users.total`; `users.activeMonth` and `activeHalfyear` always null; `localPosts`; `localComments` 0).
- `metadata`: `nodeName`, `nodeDescription`, `nodeAdmins`, `maintainer` (deprecated), `langs`, `tosUrl`, `privacyPolicyUrl`, `inquiryUrl`, `impressumUrl`, `repositoryUrl`, `feedbackUrl`, `disableRegistration`, `disableLocalTimeline`, `disableGlobalTimeline`, `emailRequiredForSignup`, `enableHcaptcha`, `enableRecaptcha`, `enableMcaptcha`, `enableTurnstile`, `enableEmail`, `enableServiceWorker`, `maxNoteTextLength`, `proxyAccountName`, `themeColor`.
- The file does not hide anything when federation is off. Any gating happens elsewhere.

## Misskey as a client **[src]** `core/FetchInstanceMetadataService.ts`

1. It fetches `https://<host>/.well-known/nodeinfo` as JSON. A 404 is `No nodeinfo provided`.
2. It accepts only the `rel` values for schema 1.0, 2.0, and 2.1, and prefers 2.1, then 2.0, then 1.0. The order of the links in the document does not matter.
3. It reads `software.name` (lowercased), `software.version`, `openRegistrations`, and `metadata.maintainer.name` and `.email`.
4. Display name: `metadata.nodeName`, then `metadata.name`, then the page's `og:title`, then the web manifest's name.
5. Description: `metadata.nodeDescription`, then `metadata.description`, then the page's `description` and `og:description`.
6. Theme colour: `metadata.themeColor`, then the page's `theme-color`, then the manifest.
7. It also fetches the home page, `/manifest.json`, and a favicon (`/favicon.ico` by `HEAD` if the page has no `<link rel="icon">`).
8. One failing source does not stop the others. The data is refreshed at most once a day unless forced.

## What sukhi does **[sukhi]** `web/nodeinfo_controller.ex`

- The discovery document lists 2.0 and then 2.1, and the same body is served at both. Misskey prefers 2.1 whatever the order.
- `software.name` is `sukhi-fedi`. Misskey lowercases it, which changes nothing.
- `metadata` is `{}`. Misskey therefore uses sukhi's home page and manifest for name, description, and colour.
- `activeMonth` and `activeHalfyear` are 0. Misskey sends null for both. A reader should rely on neither.

What a `metadata` object that gives Misskey the values directly would look like (type `NodeInfoMetadata`):
```json
{
  "nodeName": "sukhi",
  "nodeDescription": "A small server",
  "themeColor": "#86b300",
  "maintainer": {
    "name": "hina",
    "email": "admin@sukhi.social"
  }
}
```

The type, written as JSDoc so the page can be read on its own (the checker compiles it):

```js
/**
 * The `metadata` keys Misskey's instance fetcher reads. All are optional.
 * sukhi sends an empty object.
 * @typedef {object} NodeInfoMetadata
 * @property {string} [nodeName]
 * @property {string} [name]  Read when `nodeName` is absent.
 * @property {string} [nodeDescription]
 * @property {string} [description]  Read when `nodeDescription` is absent.
 * @property {string} [themeColor]  A hex colour such as `#86b300`; Misskey normalises it.
 * @property {{name?: string, email?: string}} [maintainer]
 */
```

This is a gap in sukhi, not a fault: nothing breaks without it.
