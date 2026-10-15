// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Golden-fixture generator for the Elixir port of this service.
//
// Runs the real fedify code paths (builders, signJsonLd, signRequest)
// with a fixed keypair and fixed inputs, and dumps the results as JSON.
// The Elixir test suite then proves compatibility the strong way: its
// canonicalization + verification must accept what fedify produced.
//
// Usage: node --import @oxc-node/core/register scripts/dump_golden.ts > ../elixir/test/support/fixtures/fedify_golden.json

import { generateCryptoKeyPair, exportJwk, signRequest, signJsonLd, signObject, verifyProof } from "@fedify/fedify";
import { Announce, Multikey } from "@fedify/fedify/vocab";
import { Temporal } from "@js-temporal/polyfill";
import { handleBuildNote } from "../handlers/build/note.ts";
import { handleBuildFollow } from "../handlers/build/follow.ts";
import { handleBuildAnnounce } from "../handlers/build/announce.ts";
import { handleBuildLike } from "../handlers/build/like.ts";
import { handleBuildEmojiReact } from "../handlers/build/emoji_react.ts";
import { handleBuildUndo } from "../handlers/build/undo.ts";
import { handleBuildDelete } from "../handlers/build/delete.ts";
import { handleBuildAdd } from "../handlers/build/collection_op.ts";

const ACTOR = "https://sukhi.test/users/shiro";
const KEY_ID = `${ACTOR}#main-key`;

const { privateKey, publicKey } = await generateCryptoKeyPair("RSASSA-PKCS1-v1_5");
const privateKeyJwk = await exportJwk(privateKey);
const publicKeyJwk = await exportJwk(publicKey);

const creds = { privateKeyJwk, keyId: KEY_ID } as const;

const note = await handleBuildNote({
  ...creds,
  actor: ACTOR,
  content: "<p>golden fixture — こんにちは</p>",
  recipientInboxes: ["https://remote.test/inbox"],
  noteId: "https://sukhi.test/notes/1",
  activityId: "https://sukhi.test/notes/1/activity",
  quoteUrl: "https://remote.test/notes/9",
  inReplyToId: "https://remote.test/notes/8",
  attachments: [
    {
      url: "https://media.sukhi.test/1.webp",
      mediaType: "image/webp",
      name: "alt text",
      width: 800,
      height: 600,
    },
  ],
});

const follow = await handleBuildFollow({
  ...creds,
  actor: ACTOR,
  object: "https://remote.test/users/friend",
  activityId: "https://sukhi.test/follows/1",
});

const announce = await handleBuildAnnounce({
  ...creds,
  actor: ACTOR,
  object: "https://remote.test/notes/9",
  activityId: "https://sukhi.test/announces/1",
  recipientInboxes: ["https://remote.test/inbox"],
});

const like = await handleBuildLike({
  ...creds,
  actor: ACTOR,
  object: "https://remote.test/notes/9",
  activityId: "https://sukhi.test/likes/1",
  recipientInboxes: ["https://remote.test/inbox"],
});

const emojiReact = await handleBuildEmojiReact({
  ...creds,
  actor: ACTOR,
  object: "https://remote.test/notes/9",
  content: ":blobcat:",
  tag: {
    name: ":blobcat:",
    url: "https://sukhi.test/emoji/blobcat.png",
  },
  activityId: "https://sukhi.test/likes/2",
  recipientInboxes: ["https://remote.test/inbox"],
});

const undo = await handleBuildUndo({
  ...creds,
  actor: ACTOR,
  activityId: "https://sukhi.test/undos/1",
  recipientInboxes: ["https://remote.test/inbox"],
  inner: {
    type: "Like",
    id: "https://sukhi.test/likes/1",
    object: "https://remote.test/notes/9",
  },
});

const del = await handleBuildDelete({
  ...creds,
  actor: ACTOR,
  activityId: "https://sukhi.test/deletes/1",
  objectId: "https://sukhi.test/notes/1",
  recipientInboxes: ["https://remote.test/inbox"],
});

const add = await handleBuildAdd({
  ...creds,
  actor: ACTOR,
  objectUri: "https://sukhi.test/notes/1",
  targetUri: `${ACTOR}/collections/featured`,
  activityId: "https://sukhi.test/adds/1",
  recipientInboxes: ["https://remote.test/inbox"],
});

// LD signatures over documents whose timestamps are already in
// xsd:dateTime canonical form (no fractional seconds). The builder
// outputs above carry Temporal's nanosecond `published`, which rdf.ex
// cannot reproduce verbatim (it truncates to microseconds); these
// fixtures prove pipeline compatibility for the values the Elixir
// builders actually emit. The Elixir context constant is used verbatim
// so its expansion is covered too.
const elixirContext = [
  "https://www.w3.org/ns/activitystreams",
  "https://w3id.org/security/v1",
  "https://w3id.org/security/data-integrity/v1",
  {
    toot: "http://joinmastodon.org/ns#",
    misskey: "https://misskey-hub.net/ns#",
    sensitive: "as:sensitive",
    Hashtag: "as:Hashtag",
    Emoji: "toot:Emoji",
    _misskey_content: "misskey:_misskey_content",
    _misskey_quote: "misskey:_misskey_quote",
    quoteUrl: "as:quoteUrl",
  },
];

const announceCanonical = await signJsonLd(
  {
    "@context": elixirContext,
    id: "https://sukhi.test/announces/2",
    type: "Announce",
    actor: ACTOR,
    object: "https://remote.test/notes/9",
    published: "2026-06-11T08:00:00Z",
    to: ["https://www.w3.org/ns/activitystreams#Public"],
    cc: [`${ACTOR}/followers`],
  },
  privateKey,
  new URL(KEY_ID),
  {},
);

const noteCanonical = await signJsonLd(
  {
    "@context": elixirContext,
    id: "https://sukhi.test/notes/3/activity",
    type: "Create",
    actor: ACTOR,
    to: ["https://www.w3.org/ns/activitystreams#Public"],
    cc: [`${ACTOR}/followers`],
    object: {
      id: "https://sukhi.test/notes/3",
      type: "Note",
      attributedTo: ACTOR,
      content: "<p>canonical timestamps — こんにちは</p>",
      published: "2026-06-11T08:00:00Z",
      to: ["https://www.w3.org/ns/activitystreams#Public"],
      cc: [`${ACTOR}/followers`],
      inReplyTo: "https://remote.test/notes/8",
      tag: [
        {
          type: "Emoji",
          name: ":blobcat:",
          icon: { type: "Image", url: "https://sukhi.test/emoji/blobcat.png" },
        },
      ],
      attachment: [
        {
          type: "Document",
          url: "https://media.sukhi.test/1.webp",
          mediaType: "image/webp",
          width: 800,
          height: 600,
        },
      ],
    },
  },
  privateKey,
  new URL(KEY_ID),
  {},
);

// FEP-8b32 Object Integrity Proof (eddsa-jcs-2022) over a document with
// canonical timestamps, signed by fedify's real `signObject`. Ed25519
// signatures are deterministic (RFC 8032), so the Elixir Oip module can
// prove both directions against this: verifying these exact bytes, and
// reproducing the same proofValue for the same document + created + key.
const ED_KEY_ID = `${ACTOR}#ed25519-key`;
const edKeys = await generateCryptoKeyPair("Ed25519");
const ed25519PrivateKeyJwk = await exportJwk(edKeys.privateKey);
const ed25519PublicKeyJwk = await exportJwk(edKeys.publicKey);

const multikey = new Multikey({
  id: new URL(ED_KEY_ID),
  controller: new URL(ACTOR),
  publicKey: edKeys.publicKey,
});
const multikeyJson = (await multikey.toJsonLd()) as Record<string, unknown>;

const announceToProve = await Announce.fromJsonLd({
  "@context": "https://www.w3.org/ns/activitystreams",
  id: "https://sukhi.test/announces/3",
  type: "Announce",
  actor: ACTOR,
  object: "https://remote.test/notes/9",
  published: "2026-06-11T08:00:00Z",
  to: ["https://www.w3.org/ns/activitystreams#Public"],
  cc: [`${ACTOR}/followers`],
});
const announceProved = await signObject(announceToProve, edKeys.privateKey, new URL(ED_KEY_ID), {
  created: Temporal.Instant.from("2026-06-11T08:00:00Z"),
});
const announceWithProof = (await announceProved.toJsonLd({ format: "compact" })) as Record<string, unknown>;

// fedify hashes (and delivers) the *normalized* compact form, where the
// `as:Public` CURIE compaction artifact is expanded back to the full
// URI (`normalizeOutgoingActivityJsonLd`). Plain `toJsonLd` skips that
// step, so apply it here — otherwise the fixture's bytes are not the
// bytes the proof signs and on-wire receivers see.
const PUBLIC_URI = "https://www.w3.org/ns/activitystreams#Public";
for (const field of ["to", "cc", "bto", "bcc", "audience"]) {
  const value = announceWithProof[field];
  if (value === "as:Public" || value === "Public") announceWithProof[field] = PUBLIC_URI;
  if (Array.isArray(value)) {
    announceWithProof[field] = value.map((v) => (v === "as:Public" || v === "Public" ? PUBLIC_URI : v));
  }
}

// The actor document shape a fedify-family server (hackers.pub, Hollo)
// publishes the Ed25519 key in — `assertionMethod` Multikey entries.
const oipActorDocument = {
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1",
    "https://w3id.org/security/multikey/v1",
    "https://w3id.org/security/data-integrity/v1",
  ],
  id: ACTOR,
  type: "Person",
  preferredUsername: "shiro",
  inbox: `${ACTOR}/inbox`,
  assertionMethod: [multikeyJson],
};

// Sanity: fedify itself must accept the exact JSON this fixture carries.
const proofs: unknown[] = [];
for await (const p of announceProved.getProofs()) proofs.push(p);
const verifiedKey = await verifyProof(announceWithProof, proofs[0] as never, {
  documentLoader: async (url: string) => ({
    document: multikeyJson,
    documentUrl: url,
    contextUrl: null,
  }),
});
if (verifiedKey == null) throw new Error("golden OIP fixture does not verify against fedify itself");

// Stronger sanity: the proof must verify over the fixture's *verbatim*
// bytes (fedify's verifyProof would silently fall back to a normalized
// candidate, which the byte-for-byte Elixir tests cannot reproduce).
{
  const serialize = (await import("json-canon")).default;
  const docPart = { ...announceWithProof };
  delete docPart.proof;
  const proofJson = (announceWithProof.proof ?? {}) as Record<string, unknown>;
  const config = {
    "@context": announceWithProof["@context"],
    type: "DataIntegrityProof",
    cryptosuite: "eddsa-jcs-2022",
    verificationMethod: proofJson.verificationMethod,
    proofPurpose: "assertionMethod",
    created: proofJson.created,
  };
  const enc = new TextEncoder();
  const proofDigest = await crypto.subtle.digest("SHA-256", enc.encode(serialize(config)));
  const msgDigest = await crypto.subtle.digest("SHA-256", enc.encode(serialize(docPart)));
  const digest = new Uint8Array(64);
  digest.set(new Uint8Array(proofDigest), 0);
  digest.set(new Uint8Array(msgDigest), 32);
  // decode multibase base58btc proofValue
  const ALPHA = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let n = 0n;
  for (const c of String(proofJson.proofValue).slice(1)) n = n * 58n + BigInt(ALPHA.indexOf(c));
  const bytes: number[] = [];
  while (n > 0n) {
    bytes.unshift(Number(n % 256n));
    n /= 256n;
  }
  const sig = new Uint8Array(bytes);
  const ok = await crypto.subtle.verify("Ed25519", edKeys.publicKey, sig, digest);
  if (!ok) throw new Error("golden OIP fixture does not verify over its verbatim bytes");
}

// HTTP-signed request, same shape sign_delivery.ts produces.
const body = JSON.stringify({ hello: "world" });
const request = new Request("https://remote.test/inbox", {
  method: "POST",
  headers: { "Content-Type": "application/activity+json" },
  body,
});
const signed = await signRequest(
  request,
  privateKey,
  new URL(KEY_ID),
  { spec: "draft-cavage-http-signatures-12", body: new TextEncoder().encode(body).buffer as ArrayBuffer },
);
const signedHeaders: Record<string, string> = {};
signed.headers.forEach((v, k) => {
  signedHeaders[k] = v;
});

// Same request signed with RFC 9421 (what fedify-family servers send).
const signedRfc9421 = await signRequest(
  new Request("https://remote.test/inbox", {
    method: "POST",
    headers: { "Content-Type": "application/activity+json" },
    body,
  }),
  privateKey,
  new URL(KEY_ID),
  { spec: "rfc9421", body: new TextEncoder().encode(body).buffer as ArrayBuffer },
);
const signedRfc9421Headers: Record<string, string> = {};
signedRfc9421.headers.forEach((v, k) => {
  signedRfc9421Headers[k] = v;
});

console.log(JSON.stringify(
  {
    actor: ACTOR,
    keyId: KEY_ID,
    privateKeyJwk,
    publicKeyJwk,
    builders: {
      note,
      follow,
      announce,
      like,
      emoji_react: emojiReact,
      undo,
      delete: del,
      add,
    },
    http_signature: {
      url: "https://remote.test/inbox",
      method: "POST",
      body,
      headers: signedHeaders,
    },
    http_signature_rfc9421: {
      url: "https://remote.test/inbox",
      method: "POST",
      body,
      headers: signedRfc9421Headers,
    },
    ld_signatures: {
      announce_canonical: announceCanonical,
      note_canonical: noteCanonical,
    },
    oip: {
      keyId: ED_KEY_ID,
      privateKeyJwk: ed25519PrivateKeyJwk,
      publicKeyJwk: ed25519PublicKeyJwk,
      multikey: multikeyJson,
      actor_document: oipActorDocument,
      created: "2026-06-11T08:00:00Z",
      announce_with_proof: announceWithProof,
    },
  },
  null,
  2,
));
