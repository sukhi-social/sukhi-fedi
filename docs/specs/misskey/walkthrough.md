<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: A walk-through

- Part of [the Misskey specification](README.md); source tags and terms are explained there.

## In one paragraph

Alice has an account on a Misskey server, `misskey.example`. Bob has one on yours, `other.example`. Alice finds Bob, follows him, and later Bob posts a note that Alice reads. This page tells that story in order, so you can see where each rule from the other pages comes into play. Every step names the page with the details. Nothing here is new information.

## 1. Alice types `@bob@other.example`

Misskey does not know Bob, so it asks his server where he is. It sends

```
GET https://other.example/.well-known/webfinger?resource=acct:bob@other.example
Accept: application/jrd+json, application/json
```

and expects a JSON answer with a `self` link. It takes the first link whose `rel` is `self` and does not look at its `type`.
Details: [webfinger](webfinger.md).

## 2. Misskey fetches Bob's actor

It does a `GET` on the `self` link. Misskey is able to sign such a request with a key of one of its own users, so your server may be asked for a signature; it sends `Accept: application/activity+json, application/ld+json; profile="https://www.w3.org/ns/activitystreams"`. It needs `id`, `inbox`, and `preferredUsername` in the answer, and `id`, `inbox`, `outbox`, `followers`, `following`, and the key's id must be on `other.example`.
Details: [actor](actor.md) (`#InActor`), [signatures](signatures.md) (signed `GET`).

While it is there, Misskey may also look at `https://other.example/.well-known/nodeinfo` to show what software your server runs ([nodeinfo](nodeinfo.md)).

## 3. Alice presses Follow

Misskey sends a `Follow` to Bob's inbox:

```
POST https://other.example/inbox
Content-Type: application/activity+json
Date: Fri, 23 Oct 2026 09:00:00 GMT
Digest: SHA-256=<base64 of the body>
Signature: keyId="https://misskey.example/users/a1#main-key",algorithm="rsa-sha256",
  headers="(request-target) date host digest",signature="..."
```

The body is the activity of type `#Follow`. The `id` is on `misskey.example`.
Details: [activities](activities.md) (what it sends), [signatures](signatures.md) (the headers), [transport](transport.md).

## 4. Your server checks the delivery

Check the `Digest`, then the signature against Alice's key, which you fetch from her actor (`https://misskey.example/users/a1`). Her key's owner must be the `actor` of the activity, and the activity's `id` must be on her host. Misskey signs `(request-target) date host digest`, with RSA and `rsa-sha256`; it does not use RFC 9421.
Details: [signatures](signatures.md).

## 5. Bob accepts

Your server answers with an `Accept`. Misskey wants the *whole* `Follow` in `object`, as it was sent, with its original `id`. You sign this request in the same way and `POST` it to Alice's inbox. (Misskey's two inbox URLs, `/inbox` and `/users/<id>/inbox`, run the same code.)

If Bob's account is locked, the same step is delayed until Bob decides. Misskey keeps the request pending until then.
Details: [activities-received](activities-received.md) (`#InAccept`, "Following, step by step"), [delivery](delivery.md).

## 6. Bob posts

Your server `POST`s a `Create` with a `Note` to the shared inbox of `misskey.example`, because Alice follows him. Misskey checks the signature as in step 4, then reads the note:

- `id` and `attributedTo` must be on your host, and `attributedTo` must be the sender;
- `to` and `cc` decide who may see it: Public in `to` is public, Public in `cc` is "home", the followers collection is "followers", anything else is direct ([note](note.md));
- the text comes from `content` (HTML); if you also send `_misskey_content` and `source`, Misskey takes your source as its own markup ([mfm](mfm.md)).

Details: [note](note.md), [objects](objects.md) (`#InNote`), [activities-received](activities-received.md) (`#InCreate`).

## 7. Alice reacts, and something fails

Alice answers with a `Like` that carries a `content` such as 👍 or `:blobcat:` ([reactions](reactions.md)). If your server is down when Misskey tries, it tries again: 12 times over about a day and a third. It does not try again after a 4xx other than 429 ([delivery](delivery.md)).

## Where to go next

- To serve what Misskey asks for beyond this story: [transport](transport.md), [collections](collections.md).
- To learn a Misskey-only feature: [mfm](mfm.md), [emoji](emoji.md), [quote](quote.md), [poll](poll.md).
- To look up a word: the table of terms in the [README](README.md#terms).
