<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Objects

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Types: `#Note`, `#Person`, `#Emoji`, `#Hashtag`, `#Mention`, `#Document`, `#Image`, `#Key`, `#PropertyValue`, `#Tombstone`, `#Context`, defined below

## In one paragraph

These are the objects that Misskey writes into activities and actor documents. Each type below lists every property Misskey's code writes, and no others, so a property that is not in the type is not sent. A property that Misskey leaves out when it has no value is optional in the type; one that can be `null` says so. [Activities](activities.md) uses these types.

Source of this page: **[src]** `ApRendererService.ts` (the `render*` functions named in the comments) and `misc/contexts.ts`.

## Shared pieces

```cue
// A date as `Date.toISOString()` writes it.
#DateTime: =~"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"

#Public: "https://www.w3.org/ns/activitystreams#Public"

// `addContext` puts this on the top level of every activity Misskey sends,
// and the actor and note endpoints put it on the objects they serve.
#Context: [
	"https://www.w3.org/ns/activitystreams",
	"https://w3id.org/security/v1",
	{
		Key:                                     "sec:Key"
		manuallyApprovesFollowers:               "as:manuallyApprovesFollowers"
		sensitive:                               "as:sensitive"
		Hashtag:                                 "as:Hashtag"
		quoteUrl:                                "as:quoteUrl"
		toot:                                    "http://joinmastodon.org/ns#"
		Emoji:                                   "toot:Emoji"
		featured:                                "toot:featured"
		discoverable:                            "toot:discoverable"
		schema:                                  "http://schema.org#"
		PropertyValue:                           "schema:PropertyValue"
		value:                                   "schema:value"
		misskey:                                 "https://misskey-hub.net/ns#"
		"_misskey_content":                      "misskey:_misskey_content"
		"_misskey_quote":                        "misskey:_misskey_quote"
		"_misskey_reaction":                     "misskey:_misskey_reaction"
		"_misskey_votes":                        "misskey:_misskey_votes"
		"_misskey_summary":                      "misskey:_misskey_summary"
		"_misskey_followedMessage":              "misskey:_misskey_followedMessage"
		"_misskey_requireSigninToViewContents":  "misskey:_misskey_requireSigninToViewContents"
		"_misskey_makeNotesFollowersOnlyBefore": "misskey:_misskey_makeNotesFollowersOnlyBefore"
		"_misskey_makeNotesHiddenBefore":        "misskey:_misskey_makeNotesHiddenBefore"
		"_misskey_license":                      "misskey:_misskey_license"
		freeText: {
			"@id":   "misskey:freeText"
			"@type": "schema:text"
		}
		isCat: "misskey:isCat"
		vcard: "http://www.w3.org/2006/vcard/ns#"
	},
]
```

## Tags, files, keys

`renderHashtag`, `renderMention`, `renderEmoji`, `renderDocument`, `renderImage`, `renderIdenticon`, `renderKey`, `renderTombstone`, and the profile fields of `renderPerson`.

```cue
#Hashtag: {
	type: "Hashtag"
	href: #URL
	name: =~"^#"
}

// A local user's name is `@name`; a remote user's is `@name@host`.
#Mention: {
	type: "Mention"
	href: #URL
	name: =~"^@"
}

#Emoji: {
	id:      #URL // <origin>/emojis/<name>
	type:    "Emoji"
	name:    =~"^:[^:]+:$"
	updated: #DateTime
	icon: {
		type:      "Image"
		mediaType: string
		url:       #URL
	}
	"_misskey_license": {freeText: string | null}
}

#Document: {
	type:      "Document"
	mediaType: string
	url:       #URL
	name:      string | null
	width?:    int
	height?:   int
	sensitive: bool
}

// Avatars, banners, and the identicon.
#Image: {
	type:      "Image"
	url:       #URL
	sensitive: bool
	name:      string | null
}

#Key: {
	id:           #URL // <actor>#main-key
	type:         "Key"
	owner:        #URL
	publicKeyPem: string
}

// A profile field.
#PropertyValue: {
	type:  "PropertyValue"
	name:  string
	value: string // HTML when the field value is a URL
}

#Tombstone: {
	id:   #URL
	type: "Tombstone"
}
```

## Note

**[src]** `renderNote`. Three things in it are worth knowing before the type:

- A note with a poll has `type: "Question"` instead of `"Note"`, and gains `oneOf` (single choice) or `anyOf` (multiple choice), and `endTime` (or `closed` when the poll is over).
- `inReplyTo` is `null` for a note that is not a reply, the URI of the parent when it has one, and a whole rendered note (one level deep) when the parent is local and not yet federated.
- `_misskey_content` and `source` appear together, or not at all ([mfm](mfm.md)); `_misskey_quote` and `quoteUrl` appear together or not at all ([quote](quote.md)).
- Misskey does not write `url` on a note, although it reads one.

```cue
#NoteCore: {
	"@context"?:  #Context // present when the note is served on its own URL
	id:           #URL     // <origin>/notes/<id>
	attributedTo: #URL
	summary?:     string // the content warning; U+200B when it is empty
	content?:     string
	// `_misskey_content` and `source` come together and say the same thing;
	// `_misskey_quote` and `quoteUrl` likewise.
	"_misskey_content"?: string
	source?: {
		content:   string
		mediaType: "text/x.misskeymarkdown"
	}
	if source != _|_ {
		text="_misskey_content": string
		_sameText: text & source.content
	}
	if source == _|_ {
		"_misskey_content"?: _|_
	}
	quoteUrl?:         #URL
	"_misskey_quote"?: #URL
	if quoteUrl != _|_ {
		quote="_misskey_quote": #URL
		_sameQuote: quote & quoteUrl
	}
	if quoteUrl == _|_ {
		"_misskey_quote"?: _|_
	}
	published:  #DateTime
	to:         [...string]
	cc:         [...string]
	attachment: [...#Document]
	sensitive:  bool
	tag: [...(#Hashtag | #Mention | #Emoji)]
}

#Choice: {
	type: "Note"
	name: string
	replies: {
		type:       "Collection"
		totalItems: int
	}
}

// The parent of a reply, when Misskey renders it inside the reply.
#InnerNote: {
	#NoteCore
	type:       "Note"
	inReplyTo?: null | #URL
}

#Note: {
	#NoteCore
	type:       "Note"
	inReplyTo?: null | #URL | #InnerNote
} | {
	#NoteCore
	type:       "Question"
	inReplyTo?: null | #URL | #InnerNote
	endTime?:   #DateTime | null
	closed?:    #DateTime | null
	oneOf?:     [...#Choice]
	anyOf?:     [...#Choice]
}
```

Examples. A plain reply (type `#Note`):
```json
{
  "id": "https://misskey.example/notes/9abc",
  "type": "Note",
  "attributedTo": "https://misskey.example/users/a1",
  "content": "<p>Hello</p>",
  "published": "2026-10-23T09:00:00.000Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://misskey.example/users/a1/followers"],
  "inReplyTo": "https://other.example/notes/1",
  "attachment": [],
  "sensitive": false,
  "tag": []
}
```

A note with MFM, a quote, a hashtag, and a poll (type `#Note`):
```json
{
  "id": "https://misskey.example/notes/9abd",
  "type": "Question",
  "attributedTo": "https://misskey.example/users/a1",
  "content": "<p><b>Lunch?</b> <a href=\"https://misskey.example/tags/food\" rel=\"tag\">#food</a></p><br><br><span class=\"quote-inline\">RE: <a href=\"https://other.example/notes/1\">https://other.example/notes/1</a></span>",
  "_misskey_content": "**Lunch?** #food",
  "source": {
    "content": "**Lunch?** #food",
    "mediaType": "text/x.misskeymarkdown"
  },
  "_misskey_quote": "https://other.example/notes/1",
  "quoteUrl": "https://other.example/notes/1",
  "published": "2026-10-23T09:05:00.000Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://misskey.example/users/a1/followers"],
  "inReplyTo": null,
  "attachment": [],
  "sensitive": false,
  "tag": [
    {
      "type": "Hashtag",
      "href": "https://misskey.example/tags/food",
      "name": "#food"
    }
  ],
  "endTime": "2026-10-24T09:05:00.000Z",
  "oneOf": [
    {
      "type": "Note",
      "name": "Ramen",
      "replies": {"type": "Collection", "totalItems": 2}
    },
    {
      "type": "Note",
      "name": "Curry",
      "replies": {"type": "Collection", "totalItems": 1}
    }
  ]
}
```

## Person

**[src]** `renderPerson`. `type` is `Application` for a system account (a name with a dot), `Service` for a bot, and `Person` otherwise.

```cue
#Person: {
	"@context"?: #Context // present when the actor is served on its own URL
	type: "Person" | "Service" | "Application"
	id:   #URL // <origin>/users/<id>
	inbox:       #URL
	outbox:      #URL
	followers:   #URL
	following:   #URL
	featured:    #URL // <actor>/collections/featured
	sharedInbox: #URL
	endpoints: {sharedInbox: #URL}
	url:               #URL
	preferredUsername: string
	name:              string | null
	summary:           string | null // HTML made from the MFM
	"_misskey_summary":                      string | null // the MFM source
	"_misskey_followedMessage":              string | null
	"_misskey_requireSigninToViewContents":  bool
	"_misskey_makeNotesFollowersOnlyBefore": int | null
	"_misskey_makeNotesHiddenBefore":        int | null
	icon:                      #Image
	image:                     #Image | null
	tag:                       [...(#Emoji | #Hashtag)]
	manuallyApprovesFollowers: bool
	discoverable:              bool
	publicKey:                 #Key
	isCat:                     bool
	attachment?: [#PropertyValue, ...#PropertyValue]
	movedTo?:      #URL
	alsoKnownAs?:  [...#URL]
	"vcard:bday"?:    string
	"vcard:Address"?: string
}
```

An actor (type `#Person`):
```json
{
  "type": "Person",
  "id": "https://misskey.example/users/a1",
  "inbox": "https://misskey.example/users/a1/inbox",
  "outbox": "https://misskey.example/users/a1/outbox",
  "followers": "https://misskey.example/users/a1/followers",
  "following": "https://misskey.example/users/a1/following",
  "featured": "https://misskey.example/users/a1/collections/featured",
  "sharedInbox": "https://misskey.example/inbox",
  "endpoints": {"sharedInbox": "https://misskey.example/inbox"},
  "url": "https://misskey.example/@alice",
  "preferredUsername": "alice",
  "name": "Alice",
  "summary": "<p>Hi</p>",
  "_misskey_summary": "Hi",
  "_misskey_followedMessage": null,
  "_misskey_requireSigninToViewContents": false,
  "_misskey_makeNotesFollowersOnlyBefore": null,
  "_misskey_makeNotesHiddenBefore": null,
  "icon": {
    "type": "Image",
    "url": "https://misskey.example/identicon/a1",
    "sensitive": false,
    "name": null
  },
  "image": null,
  "tag": [],
  "manuallyApprovesFollowers": false,
  "discoverable": true,
  "publicKey": {
    "id": "https://misskey.example/users/a1#main-key",
    "type": "Key",
    "owner": "https://misskey.example/users/a1",
    "publicKeyPem": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----\n"
  },
  "isCat": false
}
```

## What Misskey reads from objects

**[src]** `ApNoteService.ts` (`createNote`, `extractEmojis`), `ApPersonService.ts` (`validateActor`, `createPerson`), `ApQuestionService.ts`, `ApImageService.ts`, `ApMentionService.ts`, `type.ts`.

The types above say what Misskey writes. What Misskey accepts is wider, but once it has taken the values it needs, it uses only those. The types below list exactly the properties it reads (`#In...`); every other property is ignored, which is why they stay open (`...`). A property listed here with no `?` is one whose absence makes Misskey refuse the object.

Rules that no type can say, all **[src]**:

- A note's `id` and `url` must be https. Its `id` and `attributedTo` must be on the host it was fetched from, and `attributedTo` must be the sending actor.
- `published`, if present, must be a sane date.
- An actor's `id`, `inbox`, `outbox`, `followers`, `following`, and `publicKey.id` must be on the host the actor was fetched from. A shared inbox on another host is dropped.
- `preferredUsername` is at most 128 characters; `name` and `summary` are cut when long.
- An attachment or emoji `url` must be a string; an attachment must be https.
- `type` may be an array; Misskey uses its first element.

```cue
// An id, as `getApId` reads it: a string, or an object with an `id`.
#Ref: #URL | {id: #URL, ...}

// One reference or several. `getOneApId` takes the first.
#Refs: #Ref | [#Ref, ...#Ref]

// A link, as `getApHrefNullable` reads it.
#Href: #URL | {href: #URL, ...}

#InHashtag: {
	type: "Hashtag" | ["Hashtag", ...string]
	name: string
	...
}

#InMention: {
	type: "Mention" | ["Mention", ...string]
	href: #URL
	...
}

// `isEmoji` needs a single `icon` object with a `url`.
#InEmoji: {
	type:     "Emoji" | ["Emoji", ...string]
	id?:      #URL
	name:     string // colons are stripped
	updated?: string
	icon: {url: #URL, ...}
	"_misskey_license"?: {freeText: string | null, ...}
	...
}

#InDocument: {
	type:       "Audio" | "Document" | "Image" | "Page" | "Video"
	url:        #URL
	name?:      string | null
	sensitive?: bool
	...
}

#InChoice: {
	name?: string
	replies?: {totalItems?: int, ...}
	"_misskey_votes"?: int
	...
}

// Any post type; Misskey makes a note of it.
#InNote: {
	id:            #URL
	type:          "Note" | "Question" | "Article" | "Audio" | "Document" | "Image" | "Page" | "Video" | "Event"
	attributedTo?: #Refs // when absent in a Create, the activity's actor is used
	url?:          #Href | [#Href, ...#Href]
	published?:    string
	summary?:      string // "" means no content warning
	name?:         string // the title, or the choice of a vote
	content?:      string | null
	source?: {
		content:   string
		mediaType: string // only `text/x.misskeymarkdown` is used
		...
	}
	"_misskey_content"?: string
	"_misskey_quote"?:   string
	quoteUrl?:           string
	to?:                 #Refs
	cc?:                 #Refs
	inReplyTo?:          #Ref
	attachment?:         #InDocument | [...#InDocument]
	sensitive?:          bool
	tag?:                [...(#InHashtag | #InMention | #InEmoji | {type: _, ...})] | {...}
	endTime?:            string
	closed?:             string
	oneOf?:              [...#InChoice]
	anyOf?:              [...#InChoice]
	...
}

#InActor: {
	type:               "Person" | "Service" | "Group" | "Organization" | "Application"
	id:                 #URL
	inbox:              #URL
	sharedInbox?:       #Ref
	endpoints?:         {sharedInbox?: #Ref, ...}
	outbox?:            #Ref
	followers?:         #Ref
	following?:         #Ref
	featured?:          #Ref
	preferredUsername:  =~"^\\w([\\w.-]*\\w)?$"
	name?:              string
	summary?:           string
	"_misskey_summary"?:           string
	"_misskey_followedMessage"?:   string | null
	url?:               #Href | [#Href, ...#Href]
	icon?:              _
	image?:             _
	tag?:               _
	attachment?:        _
	publicKey?:         {id: #URL, publicKeyPem: string, ...}
	manuallyApprovesFollowers?: bool
	discoverable?:      bool
	movedTo?:           #URL
	alsoKnownAs?:       #URL | [...#URL]
	isCat?:             bool
	// read without the `_misskey_` prefix, although Misskey writes them with it
	requireSigninToViewContents?:  bool
	makeNotesFollowersOnlyBefore?: int | null
	makeNotesHiddenBefore?:        int | null
	"vcard:bday"?:      string
	"vcard:Address"?:   string
	...
}
```

How Misskey picks the values it keeps:

| Kept value | Taken from, in order |
| --- | --- |
| note text | `source.content` (if `source.mediaType` is `text/x.misskeymarkdown`), then `_misskey_content`, then `content` converted from HTML |
| quote | `_misskey_quote` and `quoteUrl`, both tried |
| content warning | `summary` (`""` means none) |
| visibility | `to` and `cc` ([note](note.md)) |
| poll | `anyOf` if there is no `oneOf` (multiple choice); the end is `endTime`, else `closed`; a choice's count is `replies.totalItems`, else `_misskey_votes`, else 0 |
| vote | a note whose parent is a poll and whose `name` equals a choice |
| shared inbox | `sharedInbox`, else `endpoints.sharedInbox` |
| actor description | `_misskey_summary`, else `summary` converted from HTML |
| bot flag | the type is `Service` or `Application` |
| birthday | the first `YYYY-MM-DD` of `vcard:bday` |

Note that Misskey writes `_misskey_requireSigninToViewContents`, `_misskey_makeNotesFollowersOnlyBefore`, and `_misskey_makeNotesHiddenBefore`, but reads the same three without the prefix. A Misskey server therefore does not read these settings from another Misskey server. **[src]** (compare `renderPerson` with `createPerson`)

A note as a server with no Misskey terms might send it (type `#InNote`):
```json
{
  "id": "https://other.example/notes/1",
  "type": "Note",
  "attributedTo": "https://other.example/users/b2",
  "content": "<p>Hello <a href=\"https://misskey.example/@alice\" class=\"u-url mention\">@alice</a></p>",
  "published": "2026-10-23T09:00:00Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://misskey.example/users/a1"],
  "tag": [
    {
      "type": "Mention",
      "href": "https://misskey.example/users/a1",
      "name": "@alice@misskey.example"
    }
  ]
}
```

An actor as a server with no Misskey terms might send it (type `#InActor`):
```json
{
  "type": "Person",
  "id": "https://other.example/users/b2",
  "inbox": "https://other.example/users/b2/inbox",
  "outbox": "https://other.example/users/b2/outbox",
  "preferredUsername": "bob",
  "name": "Bob",
  "publicKey": {
    "id": "https://other.example/users/b2#main-key",
    "owner": "https://other.example/users/b2",
    "publicKeyPem": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----\n"
  }
}
```
