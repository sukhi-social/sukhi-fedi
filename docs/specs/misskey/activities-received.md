<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Receiving activities

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Types: `#InCreate`, `#InDelete`, `#InUpdate`, `#InFollow`, `#InAccept`, `#InReject`, `#InAnnounce`, `#InLike`, `#InUndo`, `#InBlock`, `#InFlag`, `#InMove`, `#InAdd`, `#InRemove`, defined below; the objects they carry are `#InNote` and `#InActor` in [objects](objects.md)

## In one paragraph

Misskey accepts fourteen kinds of activity at its inbox and ignores the rest. For each, this page says what Misskey does, then which properties it reads to do it (nothing else is used, so the types are open). What Misskey *sends* is on [activities](activities.md). Two things surprise most readers: Misskey applies `Update` only to actors and polls, never to a note; and a `Follow` from a locked account is stored as a request and **not answered** until its owner decides.

**[src]** `ApInboxService.ts`

## What Misskey does with each activity

| Type | What Misskey does |
| --- | --- |
| Create | Creates a post only (`Note` and the other post types). `attributedTo` must equal the actor and the note id must share the actor's host. `bear:` URIs are skipped. |
| Delete | The target type comes from `object.type`, or a Tombstone's `formerType`. A bare string has no known type. With no type, an object equal to the actor is a `Person`, otherwise a `Note`. A note is deleted only if the actor owns it. An actor is marked deleted and a deletion job is queued. |
| Update | Only actors and `Question`. Anything else is skipped. A `Note` update is therefore not applied. |
| Follow | The target must be a local user. It is handled at once. |
| Accept, Reject | Only for `Follow`. Follow ids containing `follow-relay/` go to relay logic. |
| Undo | Follow, Block, Like, Announce, Accept. Others are skipped. |
| Like | See [reactions](reactions.md). |
| Announce | The target must be a post and visible to the actor. A `bear:` target (a bearcap, a capability URL) is not supported and is skipped. Relay announces publish the note directly. A malformed `published` is rejected. |
| Block | The target must be a local user. |
| Flag | Collects `/users/` URIs, takes the first local user as the target, and puts the content in the report comment. |
| Move | Needs a target `href`; otherwise skipped. Misskey then fetches the actor again; the new account is taken from the refreshed document, and checking `alsoKnownAs` is done there (not read). |
| Add, Remove | Only pin and unpin, when the target is the actor's `featured` collection. |
| anything else | `unrecognized activity type`. |

Other rules from the same file:
- A suspended actor is ignored.
- A `Collection` or `OrderedCollection` is unpacked item by item. Items whose host differs from the actor's are skipped.


## Following, step by step

**[src]** `UserFollowingService.ts` (`follow`), `ApInboxService.ts` (`follow`, `accept`, `reject`)

When a remote user follows a local one (an incoming `Follow`, handled at once, not queued):

1. The `object` must be a local user, else the activity is skipped.
2. If the local user has blocked the follower, Misskey sends back a `Reject` and stops. If the follower has blocked the local user, the block is removed.
3. If the follow already exists, Misskey sends an `Accept` again and stops.
4. The follow needs approval if the local user is locked, or the follower's account is too new for the local user's rule, or the follower is a bot and the local user is careful about bots, or the follower's server is silenced. Then, unless one of the exceptions applies (already following; the local user follows the follower back and auto-accepts those they follow; the follower is a moved account whose old account was accepted), Misskey stores a follow request and **sends nothing yet**. The local user later answers with an `Accept` or a `Reject`.
5. Otherwise the follower is added and an `Accept` is sent, carrying the original `Follow` with the id the follower gave it.

When a local user follows a remote one, Misskey sends a `Follow` and waits as a pending request; the follow takes effect when an `Accept` arrives (an incoming `Accept` of a `Follow` whose `actor` is a local user). A `Reject` ends the request. An `Undo` of a `Follow` cancels a request or ends a follow. The `Follow` inside an `Accept` or `Reject` may be a bare URL, because Misskey fetches it; the URLs of Misskey's own follows can be fetched ([transport](transport.md)).

## What Misskey reads from each activity

The types below say which properties Misskey reads. The rest are ignored, so the types are open. The object types (`#InNote`, `#InActor`) are in [objects](objects.md).

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
