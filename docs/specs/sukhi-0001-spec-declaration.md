<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-0001: Declaring implemented specifications

- Status: Draft. Not implemented.
- Identifier: `https://sukhi.social/spec/sukhi-0001/1` (provisional, see [README](README.md)).
- Builds on: FEP-844e (capability discovery), FEP-d556 (server-level actor discovery), NodeInfo 2.1.

## 1. Problem

A server needs to say "I implement this specification" for FEPs, RFCs, and its own documents, in one form. NodeInfo `metadata` has no shared key names. FEP-9fde declares API operations only. FEP-844e gives the `implements` list but defines no version and no state.

## 2. Terms

MUST, SHOULD, and MAY are used as in RFC 2119.

- **Spec identifier**: a URL that names one version of one specification.
- **Declaration**: one entry in an `implements` array.

## 3. Spec identifiers

1. An identifier MUST be an absolute `https` URL.
2. For a FEP, the identifier MUST be `https://w3id.org/fep/<id>`. For an RFC, it MUST be `https://datatracker.ietf.org/doc/html/rfc<number>`.
3. For a sukhi specification, the identifier MUST end in `/<major>`, where `<major>` is a positive integer. A change that breaks a conforming implementation MUST get a new major number. The old URL MUST keep serving the old text.
4. A declaration MUST NOT use a URL whose content can change meaning without a new identifier.

## 4. Declaration

A declaration is a JSON object with these members.

| Member | Required | Value |
| --- | --- | --- |
| `href` | yes | The spec identifier. |
| `name` | no | A short label for people. |
| `status` | no | `"stable"`, `"partial"`, or `"experimental"`, in the `https://sukhi.social/ns#` namespace. |

A reader that does not know `status` MUST ignore it. A server MUST NOT use `status` to claim more than the code does. `"partial"` MUST be backed by a list of gaps in a document that `href` or the server's FEDERATION.md describes.

## 5. Where to publish

1. The server MUST publish one server-level actor of type `Application` at a stable URL. The actor MUST contain an `implements` array of declarations (FEP-844e).
2. The server MUST answer `GET /.well-known/webfinger?resource=https://<domain>/` with one link of `rel` `https://www.w3.org/ns/activitystreams#Service`, `type` `application/activity+json`, and `href` set to the actor (FEP-d556).
3. The server SHOULD copy the `href` values, and only those, into NodeInfo `metadata.implements`, and SHOULD add `metadata.actor` with the actor URL. This copy exists for aggregators that read NodeInfo only. FEP-844e advises against NodeInfo discovery, so a reader MUST treat the actor as the authority when the two differ.
4. Both outputs MUST be built from the same list in the code. No second hand-written list is allowed.

## 6. Conformance check

A test SHOULD fail when a declared identifier has no matching "implemented" row in `docs/specs/README.md`, or when an implemented row has no declaration.

## 7. Example

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/fep/844e",
    { "sukhi": "https://sukhi.social/ns#", "status": "sukhi:status" }
  ],
  "id": "https://sukhi.social/actor",
  "type": "Application",
  "implements": [
    { "href": "https://w3id.org/fep/8b32", "name": "Object Integrity Proofs", "status": "stable" },
    { "href": "https://w3id.org/fep/044f", "name": "Quote posts", "status": "partial" },
    { "href": "https://sukhi.social/spec/sukhi-0002/1", "name": "Signature scheme fallback", "status": "stable" }
  ]
}
```

## 8. Open points

- The namespace and the identifier base need a permanent domain.
- FEP-844e is a Draft, and no large server is known to read it. This specification works as a statement for people and aggregators until that changes.
- Whether the actor also needs a public key (FEP-2677 asks for one) is not decided here.
