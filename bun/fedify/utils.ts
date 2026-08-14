import { signJsonLd } from "@fedify/fedify";
import { cachedDocumentLoader as fetchDocumentLoader } from "./context.ts";
import { getImportedPrivateKey, type JwkInput } from "./key_cache.ts";

export async function serialize(
  obj: { toJsonLd(opts: { contextLoader: typeof fetchDocumentLoader }): Promise<unknown> },
): Promise<unknown> {
  return obj.toJsonLd({ contextLoader: fetchDocumentLoader });
}

// Sign an outbound Activity with RsaSignature2017 (legacy LD-Signatures)
// using the actor's published RSA key. Earlier this function used
// `signObject` from fedify v2, which only accepts Ed25519 keys — bun
// silently generated an in-memory Ed25519 keypair for it, but the
// `verificationMethod` in the proof pointed at `<actor>#main-key`,
// which resolves to the *RSA* publicKeyPem in our actor JSON. Peers
// (hackers.pub among them) then failed to verify the Ed25519 signature
// against the RSA key and rejected the activity. signJsonLd produces a
// proof whose key actually matches what we publish.
export interface SignedPayload {
  privateKeyJwk: JwkInput;
  keyId: string;
}

export async function signAndSerialize(
  creds: SignedPayload,
  obj: {
    toJsonLd(opts: { contextLoader: typeof fetchDocumentLoader }): Promise<unknown>;
  },
): Promise<unknown> {
  const jsonLd = await obj.toJsonLd({ contextLoader: fetchDocumentLoader });
  const privateKey = await getImportedPrivateKey(creds.privateKeyJwk);
  return await signJsonLd(jsonLd, privateKey, new URL(creds.keyId), {
    contextLoader: fetchDocumentLoader,
  });
}

export function injectDefined(
  obj: Record<string, unknown>,
  entries: Record<string, unknown>,
): void {
  for (const [k, v] of Object.entries(entries)) {
    if (v !== undefined) obj[k] = v;
  }
}

// A media attachment descriptor as the gateway's MediaSerialize emits
// it. `url` + `mediaType` are always present; the rest are best-effort.
export interface AttachmentDescriptor {
  url: string;
  mediaType?: string;
  name?: string;
  blurhash?: string;
  width?: number;
  height?: number;
}

// Set the inner Note's `attachment` to a list of AP `Document` objects.
// Injected post-serialize (same as _misskey_content / quote) so we keep
// full control of the Mastodon-flavoured shape — `blurhash`, `width`,
// `height` aren't standard fedify Document props and would be dropped by
// the vocab serializer. No-op when there are no attachments.
export function injectAttachments(
  activityJson: unknown,
  attachments: AttachmentDescriptor[] | undefined,
): void {
  if (!attachments || attachments.length === 0) return;
  if (
    activityJson && typeof activityJson === "object" &&
    "object" in activityJson
  ) {
    const obj = (activityJson as Record<string, unknown>).object;
    if (obj && typeof obj === "object") {
      (obj as Record<string, unknown>).attachment = attachments.map((a) => {
        const doc: Record<string, unknown> = { type: "Document", url: a.url };
        injectDefined(doc, {
          mediaType: a.mediaType,
          name: a.name,
          blurhash: a.blurhash,
          width: a.width,
          height: a.height,
        });
        return doc;
      });
    }
  }
}

export function injectMisskey(activityJson: unknown, content: string): void {
  if (
    activityJson && typeof activityJson === "object" &&
    "object" in activityJson
  ) {
    const obj = (activityJson as Record<string, unknown>).object;
    if (obj && typeof obj === "object") {
      injectDefined(obj as Record<string, unknown>, {
        _misskey_content: content,
      });
    }
  }
}

export interface EmojiDescriptor {
  shortcode?: string;
  name?: string;
  url: string;
}

export function injectEmojis(
  activityJson: unknown,
  emojis: EmojiDescriptor[] | undefined,
): void {
  if (!emojis || emojis.length === 0) return;
  if (
    activityJson && typeof activityJson === "object" &&
    "object" in activityJson
  ) {
    const obj = (activityJson as Record<string, unknown>).object;
    if (obj && typeof obj === "object") {
      const o = obj as Record<string, unknown>;
      const tags = Array.isArray(o.tag) ? o.tag : o.tag ? [o.tag] : [];
      for (const e of emojis) {
        const rawName = e.name || e.shortcode;
        if (!rawName || !e.url) continue;
        const name = rawName.startsWith(":") ? rawName : `:${rawName}:`;
        tags.push({
          type: "Emoji",
          name: name,
          icon: {
            type: "Image",
            url: e.url,
          },
        });
      }
      o.tag = tags;
    }
  }
}

// Tag a Create(Note)'s inner object as a quote-note. We emit all three
// shapes so the widest set of peers picks it up: Misskey's
// `_misskey_quote`, the cross-fork `quoteUrl`, and the FEP-e232 `tag`
// Link (Mastodon's quote-post path). No-op when there is no quote.
export function injectQuote(
  activityJson: unknown,
  quoteUri: string | null | undefined,
): void {
  if (!quoteUri) return;
  if (
    activityJson && typeof activityJson === "object" &&
    "object" in activityJson
  ) {
    const obj = (activityJson as Record<string, unknown>).object;
    if (obj && typeof obj === "object") {
      const o = obj as Record<string, unknown>;
      injectDefined(o, {
        quoteUrl: quoteUri,
        _misskey_quote: quoteUri,
      });

      // FEP-e232: append a quote Link to `tag`, preserving any existing
      // tags (mentions, hashtags, emoji).
      const tags = Array.isArray(o.tag) ? o.tag : o.tag ? [o.tag] : [];
      tags.push({
        type: "Link",
        mediaType: 'application/ld+json; profile="https://www.w3.org/ns/activitystreams"',
        href: quoteUri,
        name: `RE: ${quoteUri}`,
        rel: "https://misskey-hub.net/ns#_misskey_quote",
      });
      o.tag = tags;
    }
  }
}

/**
 * その投稿を、人が読みに行くところ。
 *
 * AP の `id` は機械の識別子で、`url` は「見に行くならここ」── 別のもの
 * なのに、こちらは `id` しか出していなかった。受け取った側は「元の投稿を
 * 開く」の行き先を作れないまま、ただ何も起きない釦を持つことになる。
 *
 * `https://host/users/name` と `.../notes/123` から
 * `https://host/@name/123` を組む。どちらも自分が作った文字列なので、
 * 形が違えば null を返して、何も足さない ── まちがった行き先を渡すより、
 * 渡さないほうがいい。
 */
export function humanNoteUrl(actor: string, noteId: string): string | null {
  try {
    const a = new URL(actor);
    const n = new URL(noteId);
    if (a.origin !== n.origin) return null;

    const name = a.pathname.match(/^\/users\/([^/]+)$/)?.[1];
    const id = n.pathname.match(/\/notes\/([^/]+)$/)?.[1];
    if (!name || !id) return null;

    return `${a.origin}/@${name}/${id}`;
  } catch {
    return null;
  }
}
