<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Collections

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Types: `#OrderedCollection`, `#OrderedCollectionPage`, defined below

## In one paragraph

Misskey serves four collections for a user: outbox, followers, following, and featured. The first three are an index (an `OrderedCollection` with a `first` link) plus pages (`OrderedCollectionPage`), and each has its own page size and paging parameter. Followers and following can be refused. Featured is a single `OrderedCollection` with the notes inline.

**[src]** `server/ActivityPubServerService.ts`, `ApRendererService.ts` (`renderOrderedCollection`, `renderOrderedCollectionPage`)

## What Misskey serves

| Endpoint | Page size | Paging | What is listed | Refused when |
| --- | --- | --- | --- | --- |
| `/users/:id/outbox` | 20 | `since_id` or `until_id` (not both: 400) | `Create` and `Announce` activities of public and home notes that are not local-only, newest first | federation is `none` (403) |
| `/users/:id/followers` | 10 | `cursor` | the actors' ids | the user's followers visibility is `followers` or `private` (403) |
| `/users/:id/following` | 10 | `cursor` | the actors' ids | the same, for following visibility |
| `/users/:id/collections/featured` | all | none | the pinned notes as full `Note` objects, public and home only | federation is `none` (403) |

All answer 404 for an unknown local user. The index responses carry `Cache-Control: public, max-age=180`. A page is asked for with `?page=true`; without it the index comes back. A `Note` object inside the featured collection is the same as at its own URL, so `#Note` of [objects](objects.md).

The featured path is `/users/:id/collections/featured`, not `/users/:id/featured`. A reader that follows the `featured` property of the actor is not affected; one that guesses the path is.

```cue
#OrderedCollection: {
	"@context"?:    #Context
	id:             #URL
	type:           "OrderedCollection"
	totalItems:     int
	first?:         #URL // the index of outbox, followers, following
	last?:          #URL // the outbox index only
	orderedItems?:  [...#Note] // featured only
}

#OrderedCollectionPage: {
	"@context"?:   #Context
	id:            #URL
	type:          "OrderedCollectionPage"
	partOf:        #URL
	totalItems:    int
	orderedItems:  [...(#URL | #Create | #Announce)]
	prev?:         #URL // the outbox only
	next?:         #URL
}
```

The followers index (type `#OrderedCollection`):
```json
{
  "id": "https://misskey.example/users/a1/followers",
  "type": "OrderedCollection",
  "totalItems": 12,
  "first": "https://misskey.example/users/a1/followers?page=true"
}
```

A followers page (type `#OrderedCollectionPage`):
```json
{
  "id": "https://misskey.example/users/a1/followers?page=true",
  "type": "OrderedCollectionPage",
  "partOf": "https://misskey.example/users/a1/followers",
  "totalItems": 12,
  "orderedItems": ["https://other.example/users/b2", "https://other.example/users/b3"],
  "next": "https://misskey.example/users/a1/followers?page=true&cursor=9abc"
}
```

The outbox index (type `#OrderedCollection`):
```json
{
  "id": "https://misskey.example/users/a1/outbox",
  "type": "OrderedCollection",
  "totalItems": 340,
  "first": "https://misskey.example/users/a1/outbox?page=true",
  "last": "https://misskey.example/users/a1/outbox?page=true&since_id=000000000000000000000000"
}
```

The paging links of an outbox page: `next` follows with `until_id` (older notes), and `prev` with `since_id` (newer notes). When a page is empty, neither is given.
