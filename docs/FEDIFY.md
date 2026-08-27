# Fedify integration — gotchas

> Project-specific field notes for working with
> [`@fedify/fedify`](https://fedify.dev). Records the traps we've
> already hit (with commit refs) and the ones the upstream docs flag
> that we haven't hit yet. Read this before touching anything in
> `bun/handlers/` or `bun/fedify/`. Upstream llms.txt index:
> <https://fedify.dev/llms.txt>.

> **Status (v0.3.0+):** Bun/Fedify is retired in production — the
> Elixir-native `SukhiFedi.Fedi.*` service serves all `fedify.*.v1`
> subjects now. This doc still applies to the `bun/` code, which is kept
> for the dev stack, rollback, and as the oracle that mints the golden
> fixtures the native port is checked against.

## 1. What we actually use

Fedify is a large framework (`Federation` builder, inbox listener DSL,
actor/collection/object dispatchers, built-in idempotency, instance
actor dispatcher, …). **We use none of that.** The gateway is
Elixir/Plug; Bun is a pure NATS Micro worker with no HTTP server. All
we import from Fedify is the primitive layer:

| Primitive                                  | Where                                          |
| ------------------------------------------ | ---------------------------------------------- |
| vocab classes (`Follow`, `Accept`, `Note`, `Create`, `Update`, `Undo`, `Announce`, `Like`, `Delete`, `Add`, `Remove`, `Block`, `Flag`, `Move`, `EmojiReact`, `Tombstone`) | `bun/handlers/**` |
| `.toJsonLd({ contextLoader })` / `.fromJsonLd(raw, { documentLoader })` | every handler |
| `signJsonLd` (RsaSignature2017 LD-Signature on the activity), wrapped by our `signAndSerialize` | `bun/fedify/utils.ts` → `bun/handlers/build/*.ts` |
| `signRequest(req, key, keyId, { preferRfc9421 })`             | `bun/handlers/sign_delivery.ts` |
| `verifyRequest(req, { documentLoader })`                      | `bun/handlers/verify.ts`       |
| `fetchDocumentLoader`                                         | `bun/fedify/context.ts`        |
| `getAuthenticatedDocumentLoader({ keyId, privateKey })`       | `bun/handlers/inbox.ts`        |
| `generateCryptoKeyPair("Ed25519")` / `exportJwk` / `importJwk` | `bun/fedify/keys.ts`, `bun/fedify/key_cache.ts` |

Because we opted out of `createFederation(...)`, **we own everything
it would otherwise give us for free**: Accept(Follow) reply, actor
cache refresh on remote, inbox idempotency, URL reconstruction
behind a proxy, authorized-fetch scaffolding, unverified-activity
handling, shared vs personal inbox auth. Each trap below is a knob
the framework would have turned for us.

## 2. Traps we've already hit

### 2.1 The reply to Follow is Accept, not the Follow itself

`00c907c`. On receiving `Follow`, send back `Accept` wrapping the
original `Follow` as its `object`. We briefly echoed the Follow
itself — pending-follow never resolves on the remote.

```ts
new Accept({
  id: new URL(`https://${selfDomain}/activities/accept/${crypto.randomUUID()}`),
  actor: follow.objectId,   // followee (us)
  object: follow,           // the Follow we received
})
```

Pointers: `bun/handlers/inbox.ts:82-87`, `elixir/lib/sukhi_fedi/ap/instructions.ex:39-57`.

### 2.2 Accept `id` must resolve under our public domain

Same commit. Some receivers dereference the Accept `id` during
validation. If you mint the id from `conn.host` behind cloudflared
you get `https://gateway:4000/…`, which won't resolve outside the
compose network. The controller passes the real domain through as
`selfDomain`.

Pointer: `elixir/…/web/inbox_controller.ex:39-45` → `bun/handlers/inbox.ts:82`.

### 2.3 Send `Update(Actor)` after Accept and after Undo(Follow)

`b188c47`, `a07b695`. Remote servers cache our actor JSON (Mastodon's
default TTL is 24 h). Without an explicit poke, follower counts stay
stale for a day. Enqueue an `Update(Actor)` delivery to the (ex-)
follower's inbox right after the Accept or the Undo(Follow) row delete.

Pointers: `elixir/lib/sukhi_fedi/ap/actor_json.ex` (builds the JSON),
`elixir/lib/sukhi_fedi/ap/instructions.ex:113-139` (enqueue helper),
`…instructions.ex:285` (Undo path).

For the Undo case the inbox URL is heuristic (`<actor_uri>/inbox`);
works for Mastodon and fedify-based servers.

### 2.4 Split context loader (unauth) from actor loader (signed)

`1c8430b`. Two loaders, different jobs:

- **`contextLoader`** — `fetchDocumentLoader`, no HTTP signature.
  Used for `fromJsonLd` / `toJsonLd` JSON-LD context resolution
  (activitystreams, security/v1, identity/v1, legacy redirects like
  `w3id.org` → `web-payments.org`). Signing these GETs confuses hosts
  that don't expect HTTP-Signature on context URLs.
- **`actorLoader`** — `getAuthenticatedDocumentLoader(...)` when the
  inbox is user-scoped and the account has a keypair. Used only for
  `follow.getActor(...)` to dereference the remote follower. Servers
  in Mastodon Secure Mode / Misskey `authFetchRequired` mode return
  `401` for actor dereference without a signature.

Never reuse the actor loader for context fetches, and never use the
unsigned loader for actor dereferences against a secure-mode host.

Pointer: `bun/handlers/inbox.ts:44-65`.

### 2.5 Pass the receiving account's key through to Bun (authorized-fetch)

`cef872b`. The gateway is Elixir; the signing keypair lives in the
`accounts` table. Bun has no DB. So the inbox controller looks up the
receiving account by `conn.path_params["name"]` and attaches
`signAs: { keyId, privateJwk, publicJwk }` to the `fedify.inbox.v1`
payload. Bun imports the JWK and passes it to
`getAuthenticatedDocumentLoader`.

Shared inbox has no `:name` — we ship an empty `signAs`, so actor
dereference falls back to the unsigned loader. If we start federating
with strict secure-mode hosts under the shared inbox, the fix is a
shared-inbox signing identity (Fedify calls this the "instance
actor" pattern; §3.6 below).

Pointer: `elixir/…/web/inbox_controller.ex:72-86` (`sign_as_for/1`).

### 2.6 Signature covers the public URL, not the rewritten Host

`53e77c4`, `6bae594`. Remotes sign against
`https://watch-mjw.f3liz.casa/users/alice/inbox`. Cloudflared rewrites
Host to `gateway:4000`. `verifyRequest` is passed a `Request` object;
if its URL is the internal one, signature verification fails even
though the keypair is correct.

`public_url/1` rebuilds the signed URL from `Application.get_env(:sukhi_fedi, :domain)`
+ `conn.request_path` + `conn.query_string`. The helper was renamed
from `request_url` because Plug.Conn already exports that name
(commit `6bae594`).

Pointer: `elixir/…/web/inbox_controller.ex:61-65`.

### 2.7 `verifyRequest` needs the raw body, not `body_params`

Same commit bundle. Signatures cover the raw byte sequence; any
re-encoding of `body_params` through Jason breaks `content-digest`.
The controller pulls `conn.assigns[:raw_body]`, which is populated by
a body reader upstream of `Plug.Parsers`.

Pointer: `elixir/…/web/inbox_controller.ex:25-37`.

### 2.8 `toJsonLd` inlines hydrated properties

Not a commit — a shape every receiver has to know. If an activity's
property has been hydrated (via `getActor()` / `getObject()` etc.),
the subsequent `toJsonLd` serializes the nested object instead of
the bare URI string. Elixir consumers must accept both shapes:

```elixir
defp extract_uri(uri) when is_binary(uri), do: uri
defp extract_uri(%{"id" => id}) when is_binary(id), do: id
defp extract_uri(_), do: nil
```

Pointer: `elixir/…/ap/instructions.ex:106-111`.

### 2.9 NATS Micro endpoint names can't contain dots

`b3114c7`. The dot is a NATS subject separator. The public NATS
**subject** (`fedify.inbox.v1`) is dotted, but the Micro service's
internal **endpoint name** slot is not — use `fedify_inbox_v1`
there, then `subject: "fedify.inbox.v1"` as the routing override.

### 2.10 `Req` chokes if both `:connect_options` and `:finch` are set

`2988360`. When using a named Finch pool (we do —
`SukhiDelivery.Finch`, 50 × 4 per host), omit `:connect_options`. Req
interprets it as a request to spin up an ad-hoc Finch, and you get a
crash at the start of the delivery path.

Pointer: `delivery/lib/sukhi_delivery/delivery/worker.ex:59-64`.

## 3. Traps from fedify docs we haven't hit yet

### 3.1 Activity id uniqueness

Don't derive Activity `id` from `(actor, object)` alone. Follow → Undo
→ Follow on the same target produces three distinct activities. We
already mint UUIDs (`crypto.randomUUID()` / Elixir `strong_rand_bytes`)
— keep doing that. If you ever see a "duplicate activity" error from
a remote, check for deterministic id construction first.

### 3.2 Vocab classes shadow JS built-ins

`Object` and `Image` collide with globals. If you add either, import
with alias: `import { Object as ASObject, Image as ASImage } from "@fedify/fedify"`.
None of our current handlers need them.

### 3.3 Vocab objects are immutable

No property assignment after construction. Use `.clone({ ... })`:

```ts
const translated = note.clone({
  content: new LanguageString(translated, "en"),
});
```

### 3.4 Cross-origin embed re-fetch (fedify 1.9+)

When an activity arrives with an embedded object from a different
origin than its parent, `getX()` re-fetches to verify by default. That
costs a round-trip on every boost/quote. Pass `crossOrigin: "trust"`
only if you've already validated the embedding some other way.

### 3.5 `manuallyApprovesFollowers` is UI-only

The flag only flips the lock icon. Auto-Accept logic lives in our
Follow handler, which today always accepts. If we add lockable
accounts, set the flag **and** gate the Accept enqueue on a
`pending_approval` state.

### 3.6 Instance-actor pattern, if we ever need it

Some servers require a valid signature just to dereference our actor
page (authorized-fetch on the outbound side too). If remote inbound
deliveries start failing at the actor-fetch step against our shared
inbox, the fix is an Application-typed instance actor with its own
keypair, used as the signing identity for unauthenticated shared-
inbox contexts. Fedify's docs cover this as the "instance actor"
pattern; we'd implement it as a synthetic `Account` row whose
username is the domain itself.

### 3.7 `summary` is HTML

User bios are HTML — escape `<`, `>`, `&` before putting them in
`summary` or `PropertyValue.value`. Today `ActorJson.build_person`
pipes `account.summary` through verbatim. Fine for the current
self-hosted fixed-profile use case; audit before exposing user-
editable bios.

Pointer: `elixir/…/ap/actor_json.ex:31`.

### 3.8 Fedify's idempotency strategies aren't wired up

`setInboxListeners().withIdempotency("per-inbox" | "per-origin" | "global")`
doesn't apply to us because we don't use `Federation`. Our equivalents:

- **Receiving side**: `objects.ap_id` unique constraint +
  `Repo.insert(on_conflict: :nothing)` on the Follow insert.
- **Sending side**: `delivery_receipts(activity_id, inbox_url)` unique
  index, checked before every POST in `Delivery.Worker`.
- **Transport**: the `outbox` row id + 2-minute
  dedup window in the OUTBOX stream.

Three layers, same goal. Don't bolt on the fedify feature — it
wouldn't fire anyway.

### 3.9 Unverified-activity handler isn't wired up

Fedify's `onUnverifiedActivity` is the hook for edge cases like a
tombstoned actor sending an unsigned `Delete(Actor)` (their key is
410, so signature verification fails). We return 400 and move on. If
it becomes noisy, handle the no-signature-+-Delete(Actor) case
explicitly in `InboxController.handle_inbox/1` before the
`FedifyClient.verify` call.

### 3.10 Double-knocking is already handled

`sign_delivery.ts` already tries RFC 9421 first (`preferRfc9421: true`)
and falls back to draft-cavage in a catch. Fedify's `verifyRequest`
accepts both. No action needed — just don't remove the fallback
`catch` block "to simplify", it's load-bearing.

Pointer: `bun/handlers/sign_delivery.ts:41-54`.

### 3.11 Key algorithm choice

We generate Ed25519 (`bun/fedify/keys.ts:16`), which works for Object
Integrity Proofs. Mastodon interop for HTTP Signatures requires
RSA-PKCS#1-v1.5. Today local actors sign requests via the Elixir
account's RSA key stored in `accounts.private_key_jwk` (pem mirrored
in `public_key_pem` for the `publicKey` field). The Ed25519 key on
the Bun side is a throwaway for ephemeral signing of the Accept
wrapper — **if that ever goes to production delivery, it will not
verify against Mastodon.** All delivery signing already routes through
`sign_delivery.ts` with the RSA JWK from Postgres; keep it that way.

## 4. Quick reference — which primitive for what

| Need                                       | Primitive                                                      |
| ------------------------------------------ | -------------------------------------------------------------- |
| Parse incoming AP JSON                     | `<Class>.fromJsonLd(raw, { documentLoader: contextLoader })`   |
| Emit AP JSON                               | `obj.toJsonLd({ contextLoader })`                              |
| Dereference a remote actor (authed)        | `follow.getActor({ documentLoader: actorLoader })`             |
| Verify incoming HTTP signature             | `verifyRequest(request, { documentLoader })`                   |
| Sign outgoing HTTP request                 | `signRequest(req, privateKey, new URL(keyId), { preferRfc9421: true })` |
| Sign an outbound activity (LD-sig)         | `signJsonLd(jsonLd, privateKey, new URL(keyId), { contextLoader })` — via our `signAndSerialize` |
| Create actor keys                          | `generateCryptoKeyPair("Ed25519" \| "RSASSA-PKCS1-v1_5")` + `exportJwk` |
| Import stored JWK                          | `importJwk(jwk, "private" \| "public")`                        |
| Authenticated GET loader for secure hosts  | `getAuthenticatedDocumentLoader({ keyId, privateKey })`        |

## 5. When fedify upgrades

Our `package.json` pin is `@fedify/fedify: ^2.2.3`. On minor bumps:

1. Re-run `bun test` — `bun/handlers/inbox_test.ts` and
   `bun/fedify/key_cache_test.ts` cover the live surface.
2. Smoke-test a Follow/Undo round-trip against a real Mastodon
   instance — the cache-refresh behavior (§2.3) and the split loader
   (§2.4) are the bits most likely to regress.
3. Check the changelog for any changes to `toJsonLd`'s hydration
   behavior (§2.8) and to `crossOrigin` defaults (§3.4).
