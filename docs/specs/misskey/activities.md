<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Activities

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Types: `#Create`, `#Announce`, `#Delete`, `#Update`, `#Follow`, `#Accept`, `#Reject`, `#Undo`, `#Like`, `#Block`, `#Flag`, `#Move`, `#Add`, `#Remove`, `#Vote`, defined below; objects they carry are in [objects](objects.md)

## In one paragraph

Misskey sends fourteen kinds of activity and accepts fourteen at its inbox. For each, this page gives the exact shape Misskey sends (every property, no others), what it does when one arrives, the properties it reads to do so (nothing else is used), and which Misskey function builds or handles it. Two things surprise most readers: Misskey applies `Update` only to actors and polls, never to a note; and an `Accept` or `Reject` carries the whole `Follow` it answers, not just its id.

Sent: **[src]** `ApRendererService.ts` (`render*`) and the services that call it, named in each section. Received: **[src]** `ApInboxService.ts`.

## Shapes common to what Misskey sends

- Every activity Misskey delivers goes through `addContext`: it gets `"@context"` ([objects](objects.md): `#Context`), and an `id` of `<origin>/<uuid>` if it had none. So a delivered activity always has an `id`, and the types below require it. The examples leave `@context` out; the types allow it.
- An activity nested in another (the `Follow` inside an `Accept`) has no `@context`.
- `signature` is the `RsaSignature2017` Linked-Data signature that `attachLdSignature` adds; the HTTP signature is separate ([signatures](signatures.md)).
- A property that Misskey leaves `undefined` is not in the JSON, so it is optional in the types.

```cue
#Envelope: {
	"@context"?: #Context
	id:          #URL
	signature?: {
		type:           "RsaSignature2017"
		creator:        #URL
		nonce:          string
		created:        #DateTime
		domain?:        string
		signatureValue: string
	}
}
```

## Notes: Create, Announce, Delete

**Create** (`renderCreate`, from `NoteCreateService`). `to` and `cc` are copied from the note. The id is `<origin>/notes/<id>/activity`.

**Announce** (`renderAnnounce`, from `NoteCreateService`). A renote with no text. The audience follows the visibility of the renote; a visibility other than public, home, or followers throws.

**Delete** (`renderDelete`, from `NoteDeleteService`). `object` is a `Tombstone` of the note. Deleting a renote sends an `Undo` of the `Announce` instead.

```cue
#Create: {
	#Envelope
	type:      "Create"
	actor:     #URL
	published: #DateTime
	to:        [...string]
	cc:        [...string]
	object:    #Note
}

#Announce: {
	#Envelope
	type:      "Announce"
	actor:     #URL
	published: #DateTime
	to:        [...string]
	cc:        [...string]
	object:    #URL
}

#Delete: {
	#Envelope
	type:      "Delete"
	actor:     #URL
	published: #DateTime
	object:    #Tombstone
}
```

A `Create` (type `#Create`):
```json
{
  "id": "https://misskey.example/notes/9abc/activity",
  "type": "Create",
  "actor": "https://misskey.example/users/a1",
  "published": "2026-10-23T09:00:00.000Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://misskey.example/users/a1/followers"],
  "object": {
    "id": "https://misskey.example/notes/9abc",
    "type": "Note",
    "attributedTo": "https://misskey.example/users/a1",
    "content": "<p>Hello</p>",
    "published": "2026-10-23T09:00:00.000Z",
    "to": ["https://www.w3.org/ns/activitystreams#Public"],
    "cc": ["https://misskey.example/users/a1/followers"],
    "inReplyTo": null,
    "attachment": [],
    "sensitive": false,
    "tag": []
  }
}
```

An `Announce` (type `#Announce`):
```json
{
  "id": "https://misskey.example/notes/9abe/activity",
  "type": "Announce",
  "actor": "https://misskey.example/users/a1",
  "published": "2026-10-23T09:10:00.000Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://misskey.example/users/a1/followers"],
  "object": "https://other.example/notes/1"
}
```

A `Delete` (type `#Delete`):
```json
{
  "id": "https://misskey.example/7f0e3c52-1b0a-4f6e-9a1d-0a3b5c7d9e11",
  "type": "Delete",
  "actor": "https://misskey.example/users/a1",
  "published": "2026-10-23T09:20:00.000Z",
  "object": {
    "id": "https://misskey.example/notes/9abc",
    "type": "Tombstone"
  }
}
```

## Updates: Update

**Update** (`renderUpdate`). Sent in three cases: a profile change (`object` is the actor, `AccountMoveService` and the user-update path), a poll vote count change (`object` is the note rendered as a `Question`, `PollService`), and just before a `Move`. The id is `<origin>/users/<id>#updates/<epoch ms>`. It is always addressed to Public.

```cue
#Update: {
	#Envelope
	type:      "Update"
	actor:     #URL
	to:        [#Public]
	published: #DateTime
	object:    #Person | #Note
}
```

An `Update` of an actor (type `#Update`):
```json
{
  "id": "https://misskey.example/users/a1#updates/1792746000000",
  "type": "Update",
  "actor": "https://misskey.example/users/a1",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "published": "2026-10-23T09:00:00.000Z",
  "object": {
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
    "summary": null,
    "_misskey_summary": null,
    "_misskey_followedMessage": null,
    "_misskey_requireSigninToViewContents": false,
    "_misskey_makeNotesFollowersOnlyBefore": null,
    "_misskey_makeNotesHiddenBefore": null,
    "icon": {"type": "Image", "url": "https://misskey.example/identicon/a1", "sensitive": false, "name": null},
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
}
```

## Relationships: Follow, Accept, Reject, Undo, Block, Move

**Follow** (`renderFollow`, from `UserFollowingService`). The id is the stored request id, or `<origin>/follows/<follower>/<followee>`. To follow a relay, Misskey sends `renderFollowRelay`: id `<origin>/activities/follow-relay/<id>` and `object` is Public.

**Accept**, **Reject** (`renderAccept`, `renderReject`). `object` is the whole `Follow` being answered, with its original id. A `Reject` is also sent when a local user removes a follower or blocks one.

**Undo** (`renderUndo`). `object` is the whole activity being undone: a `Follow` (unfollow, or cancel a request), a `Like` (reaction removed), an `Announce` (renote deleted), or a `Block` (unblock). The `id` is `<object id>/undo` when the object is local.

**Block** (`renderBlock`, from `UserBlockingService`). Sent only to a remote blockee that has a URI.

**Move** (`renderMove`, from `AccountMoveService`). `object` is the old actor, `target` the new one. Sent to the followers of the old account, after an `Update` of that actor.

```cue
#Follow: {
	#Envelope
	type:   "Follow"
	actor:  #URL
	object: #URL | #Public
}

#Accept: {
	#Envelope
	type:   "Accept"
	actor:  #URL
	object: #Follow
}

#Reject: {
	#Envelope
	type:   "Reject"
	actor:  #URL
	object: #Follow
}

#Block: {
	#Envelope
	type:   "Block"
	actor:  #URL
	object: #URL
}

#Undo: {
	#Envelope
	type:      "Undo"
	actor:     #URL
	published: #DateTime
	object:    #Follow | #Like | #Announce | #Block
}

#Move: {
	#Envelope
	type:   "Move"
	actor:  #URL
	object: actor
	target: #URL
}
```

A `Follow` (type `#Follow`):
```json
{
  "id": "https://misskey.example/follows/a1/b2",
  "type": "Follow",
  "actor": "https://misskey.example/users/a1",
  "object": "https://other.example/users/b2"
}
```

An `Accept`, as another Misskey server sends it to a remote follower (type `#Accept`):
```json
{
  "id": "https://misskey.example/5d1e4a7c-2b9f-4e3a-8c6d-1f0a9b8c7d6e",
  "type": "Accept",
  "actor": "https://misskey.example/users/a1",
  "object": {
    "id": "https://other.example/follows/f1",
    "type": "Follow",
    "actor": "https://other.example/users/b2",
    "object": "https://misskey.example/users/a1"
  }
}
```

An `Undo` of a follow (type `#Undo`):
```json
{
  "id": "https://misskey.example/follows/a1/b2/undo",
  "type": "Undo",
  "actor": "https://misskey.example/users/a1",
  "published": "2026-10-23T09:30:00.000Z",
  "object": {
    "id": "https://misskey.example/follows/a1/b2",
    "type": "Follow",
    "actor": "https://misskey.example/users/a1",
    "object": "https://other.example/users/b2"
  }
}
```

A `Block` (type `#Block`):
```json
{
  "id": "https://misskey.example/blocks/k1",
  "type": "Block",
  "actor": "https://misskey.example/users/a1",
  "object": "https://other.example/users/b2"
}
```

A `Move` (type `#Move`):
```json
{
  "id": "https://misskey.example/moves/a1/c3",
  "type": "Move",
  "actor": "https://misskey.example/users/a1",
  "object": "https://misskey.example/users/a1",
  "target": "https://new.example/users/c3"
}
```

## Reactions and votes: Like, Create (vote)

**Like** (`renderLike`, from `ReactionService`). See [reactions](reactions.md). `object` is the note's own URI if it has one (a remote note), otherwise the local note URL.

**Vote** (`renderVote`, from `PollService`). A `Create` of a small `Note`; see [poll](poll.md). Sent only to the poll's remote owner.

```cue
#Like: {
	#Envelope
	type:                "Like"
	actor:               #URL
	object:              #URL
	content:             string & !=""
	"_misskey_reaction": content
	tag?:                [#Emoji] // only for a custom emoji that is not local-only
}

#Vote: {
	#Envelope
	type:      "Create"
	actor:     #URL
	to:        [#URL]
	published: #DateTime
	object: {
		id:           #URL
		type:         "Note"
		attributedTo: #URL
		to:           [#URL]
		inReplyTo:    #URL
		name:         string
	}
}
```

A `Like` (type `#Like`):
```json
{
  "id": "https://misskey.example/likes/r1",
  "type": "Like",
  "actor": "https://misskey.example/users/a1",
  "object": "https://other.example/notes/1",
  "content": "👍",
  "_misskey_reaction": "👍"
}
```

A vote (type `#Vote`):
```json
{
  "id": "https://misskey.example/users/a1#votes/v1/activity",
  "type": "Create",
  "actor": "https://misskey.example/users/a1",
  "to": ["https://other.example/users/b2"],
  "published": "2026-10-23T09:40:00.000Z",
  "object": {
    "id": "https://misskey.example/users/a1#votes/v1",
    "type": "Note",
    "attributedTo": "https://misskey.example/users/a1",
    "to": ["https://other.example/users/b2"],
    "inReplyTo": "https://other.example/notes/9",
    "name": "Option 2"
  }
}
```

## Profile: Add, Remove, Flag

**Add**, **Remove** (`renderAdd`, `renderRemove`, from `NotePiningService`). Pin and unpin a note. `target` is the actor's featured collection, `<origin>/users/<id>/collections/featured`. They are sent only to followers and relays, and only for a public or home note that is not local-only.

**Flag** (`renderFlag`, from `AbuseReportService`). A forwarded report. The sender is the system actor, so the reporter stays anonymous. `object` is the reported user's URI.

```cue
#Add: {
	#Envelope
	type:   "Add"
	actor:  #URL
	target: #URL
	object: #URL
}

#Remove: {
	#Envelope
	type:   "Remove"
	actor:  #URL
	target: #URL
	object: #URL
}

#Flag: {
	#Envelope
	type:    "Flag"
	actor:   #URL
	content: string
	object:  #URL
}
```

An `Add` (type `#Add`):
```json
{
  "id": "https://misskey.example/1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f",
  "type": "Add",
  "actor": "https://misskey.example/users/a1",
  "target": "https://misskey.example/users/a1/collections/featured",
  "object": "https://misskey.example/notes/9abc"
}
```

A `Flag` (type `#Flag`):
```json
{
  "id": "https://misskey.example/2c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f",
  "type": "Flag",
  "actor": "https://misskey.example/actor",
  "content": "spam",
  "object": "https://other.example/users/b2"
}
```

## What Misskey does with each activity it receives

| Type | What Misskey does |
| --- | --- |
| Create | Creates a `Post` only. `attributedTo` must equal the actor and the note id must share the actor's host. `bear:` URIs are skipped. |
| Delete | The target type comes from `object.type`, or a Tombstone's `formerType`. A bare string has no known type. With no type, an object equal to the actor is a `Person`, otherwise a `Note`. A note is deleted only if the actor owns it. An actor is marked deleted and a deletion job is queued. |
| Update | Only actors and `Question`. Anything else is skipped. A `Note` update is therefore not applied. |
| Follow | The target must be a local user. It is handled at once. |
| Accept, Reject | Only for `Follow`. Follow ids containing `follow-relay/` go to relay logic. |
| Undo | Follow, Block, Like, Announce, Accept. Others are skipped. |
| Like | See [reactions](reactions.md). |
| Announce | The target must be a post and visible to the actor. Relay announces publish the note directly. A malformed `published` is rejected. |
| Block | The target must be a local user. |
| Flag | Collects `/users/` URIs, takes the first local user as the target, and puts the content in the report comment. |
| Move | Needs a target `href`; otherwise the actor is refreshed. |
| Add, Remove | Only pin and unpin, when the target is the actor's `featured` collection. |
| anything else | `unrecognized activity type`. |

Other rules from the same file:
- A suspended actor is ignored.
- A `Collection` or `OrderedCollection` is unpacked item by item. Items whose host differs from the actor's are skipped.


## What Misskey reads from each activity

The table above says what Misskey does. The types below say which properties it reads to do it; the rest are ignored (the types are open). The object types (`#InNote`, `#InActor`) are in [objects](objects.md).

Rules that apply to all of them, **[src]** `ApInboxService.ts`, `InboxProcessorService.ts`:

- The activity needs a string `id` (a missing one is an error in most branches) and an `actor` that is the signer ([signatures](signatures.md)). For `Delete`, `Update`, `Undo`, `Add`, and `Remove`, `actor` must equal the signer or the activity is skipped.
- `type` may be an array; the first element is used.
- `object` may be a string or an object. For `Create`, `Update`, `Accept`, `Reject`, `Undo`, and `Announce`, Misskey resolves it (fetches it when it is a bare URL), so the nested object's own properties are what count.
- The activity may also be a `Collection` or an `OrderedCollection` of activities. Misskey runs each item whose `id` host equals the actor's host.

```cue
#InActivity: {
	id:    #URL
	actor: #Ref
	...
}

#InCreate: {
	#InActivity
	type:    "Create" | ["Create", ...string]
	object:  #InNote | #URL
	to?:     #Refs // merged with the object's `to`
	cc?:     #Refs
	...
}

#InDelete: {
	#InActivity
	type: "Delete" | ["Delete", ...string]
	// A bare id has no type: the target is then a Person if it equals the
	// actor, otherwise a Note. A Tombstone's `formerType` gives the type.
	object: #URL | {id: #URL, type?: string, formerType?: string, ...}
	...
}

#InUpdate: {
	#InActivity
	type:   "Update" | ["Update", ...string]
	object: #InActor | #InNote | #URL // only an actor or a Question is applied
	...
}

#InFollow: {
	#InActivity
	type:   "Follow" | ["Follow", ...string]
	object: #Ref // must be a local user
	...
}

// The Follow being answered or undone. Its `actor` is the follower.
#InFollowRef: {
	id?:    #URL
	type:   "Follow" | ["Follow", ...string]
	actor:  #Ref
	object: #Ref
	...
}

#InAccept: {
	#InActivity
	type:   "Accept" | ["Accept", ...string]
	object: #InFollowRef | #URL
	...
}

#InReject: {
	#InActivity
	type:   "Reject" | ["Reject", ...string]
	object: #InFollowRef | #URL
	...
}

#InAnnounce: {
	#InActivity
	type:       "Announce" | ["Announce", ...string]
	object:     #InNote | #URL
	to?:        #Refs
	cc?:        #Refs
	published?: string
	...
}

#InLike: {
	#InActivity
	type:   "Like" | "EmojiReaction" | "EmojiReact"
	object: #Ref
	// the reaction string is the first that is present
	"_misskey_reaction"?: string
	content?:             string
	name?:                string
	tag?:                 [...] | {...} // emoji tags are saved, see #InEmoji
	...
}

#InUndo: {
	#InActivity
	type: "Undo" | ["Undo", ...string]
	object: {
		type: "Follow" | "Block" | "Like" | "Announce" | "Accept"
		...
	} | #URL
	...
}

#InBlock: {
	#InActivity
	type:   "Block" | ["Block", ...string]
	object: #Ref // must be a local user
	...
}

#InFlag: {
	#InActivity
	type:     "Flag" | ["Flag", ...string]
	content?: string
	object:   #Refs // the first local user is the target
	...
}

#InMove: {
	#InActivity
	type:   "Move" | ["Move", ...string]
	target: #Href
	...
}

// Add and Remove: only pinning, when `target` is the actor's `featured`.
#InAdd: {
	#InActivity
	type:   "Add" | ["Add", ...string]
	target: #URL
	object: #Ref
	...
}

#InRemove: {
	#InActivity
	type:   "Remove" | ["Remove", ...string]
	target: #URL
	object: #Ref
	...
}
```

A `Create` from a server with no Misskey terms (type `#InCreate`):
```json
{
  "id": "https://other.example/notes/1/activity",
  "type": "Create",
  "actor": "https://other.example/users/b2",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "object": {
    "id": "https://other.example/notes/1",
    "type": "Note",
    "attributedTo": "https://other.example/users/b2",
    "content": "<p>Hello</p>"
  }
}
```

A `Delete` with a bare id (type `#InDelete`):
```json
{
  "id": "https://other.example/notes/1/delete",
  "type": "Delete",
  "actor": "https://other.example/users/b2",
  "object": "https://other.example/notes/1"
}
```

A `Like` as another server writes a reaction (type `#InLike`):
```json
{
  "id": "https://other.example/likes/1",
  "type": "EmojiReact",
  "actor": "https://other.example/users/b2",
  "object": "https://misskey.example/notes/9abc",
  "content": "🎉"
}
```

An `Undo` of a `Like` (type `#InUndo`):
```json
{
  "id": "https://other.example/likes/1/undo",
  "type": "Undo",
  "actor": "https://other.example/users/b2",
  "object": {
    "id": "https://other.example/likes/1",
    "type": "Like",
    "actor": "https://other.example/users/b2",
    "object": "https://misskey.example/notes/9abc"
  }
}
```

A `Follow` from a remote user (type `#InFollow`):
```json
{
  "id": "https://other.example/follows/f1",
  "type": "Follow",
  "actor": "https://other.example/users/b2",
  "object": "https://misskey.example/users/a1"
}
```

An `Accept` of a follow Misskey sent (type `#InAccept`):
```json
{
  "id": "https://other.example/accepts/1",
  "type": "Accept",
  "actor": "https://other.example/users/b2",
  "object": "https://misskey.example/follows/a1/b2"
}
```

A `Flag` (type `#InFlag`):
```json
{
  "id": "https://other.example/flags/1",
  "type": "Flag",
  "actor": "https://other.example/actor",
  "content": "spam",
  "object": ["https://misskey.example/users/a1", "https://misskey.example/notes/9abc"]
}
```

A `Move` (type `#InMove`):
```json
{
  "id": "https://other.example/moves/1",
  "type": "Move",
  "actor": "https://other.example/users/b2",
  "object": "https://other.example/users/b2",
  "target": "https://new.example/users/b3"
}
```

An `Update` of a poll (type `#InUpdate`):
```json
{
  "id": "https://other.example/updates/1",
  "type": "Update",
  "actor": "https://other.example/users/b2",
  "object": {
    "id": "https://other.example/notes/9",
    "type": "Question",
    "attributedTo": "https://other.example/users/b2",
    "oneOf": [
      {"name": "Ramen", "replies": {"totalItems": 3}},
      {"name": "Curry", "replies": {"totalItems": 1}}
    ]
  }
}
```
