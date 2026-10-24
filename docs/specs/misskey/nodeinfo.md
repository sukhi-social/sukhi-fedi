<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: NodeInfo

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Type: `#NodeInfoMetadata`, defined below

## In one paragraph

NodeInfo is a small public document that says what software a server runs. Misskey publishes one, and reads other servers'. When it reads one, it takes the display name, description, and colour from `metadata` if they are there, and from the server's web page otherwise.

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

## An example

A `metadata` object that gives Misskey the values directly (type `#NodeInfoMetadata`):
```json
{
  "nodeName": "Example",
  "nodeDescription": "A small server",
  "themeColor": "#86b300",
  "maintainer": {
    "name": "hina",
    "email": "admin@other.example"
  }
}
```

The type, in [CUE](https://cuelang.org):

```cue
// The `metadata` keys Misskey's instance fetcher reads. All are optional;
// other keys are allowed.
#NodeInfoMetadata: {
	nodeName?:        string
	name?:            string // read when `nodeName` is absent
	nodeDescription?: string
	description?:     string // read when `nodeDescription` is absent
	themeColor?:      =~"^#?[0-9a-fA-F]{3,8}$" // Misskey normalises it to hex
	maintainer?: {
		name?:  string
		email?: string
		...
	}
	...
}
```

## Things to watch

- Misskey sends `null` for `activeMonth` and `activeHalfyear`. A reader should rely on neither.
- A server whose `metadata` is empty is still shown, from its web page.
