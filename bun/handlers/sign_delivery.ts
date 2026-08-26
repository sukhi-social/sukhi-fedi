// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Sign an outbound ActivityPub POST (delivery / inbox post) and hand
// the signed headers back to Elixir. The actual HTTP POST is done by
// `SukhiDelivery.Delivery.Worker` with these headers.
//
// fedify が要求するもの:
//   - signRequest(request, privateKey, keyId, options?)
//   - options.spec = "draft-cavage-http-signatures-12" | "rfc9421"
//   - options.body = ArrayBuffer | null
//       POST body のクローンを fedify 内部でやらせると Bun で潰れる
//       ことがあった(Request.clone は仕様上 OK だが、digest 計算の
//       fast path が失敗する) ─ 明示的に渡す方が安全。
//
// fediverse の実勢:
//   - Mastodon / Misskey / Sharkey / Akkoma / Pleroma 全部 cavage-12
//   - hackers.pub のような Fedify 1.x 製も両方受けるが、cavage の方が
//     verifyRequest の fast path に乗りやすい
//   ─ 既定は cavage-12。

import { signRequest, importJwk, type HttpMessageSignaturesSpec } from "@fedify/fedify";
import { getImportedPrivateKey, type JwkInput } from "../fedify/key_cache.ts";

export interface SignDeliveryPayload {
  actorUri: string;
  inbox: string;
  body: string;
  privateKeyJwk: JwkInput;
  keyId: string;
  /**
   * Preferred HTTP Signature spec.
   * - "rfc9421"  → Signature-Input + Signature headers (RFC 9421)
   * - "cavage"   → single Signature header (draft-cavage, default)
   */
  algorithm?: "rfc9421" | "cavage";
}

export interface SignDeliveryResult {
  headers: Record<string, string>;
}

const enc = new TextEncoder();

export async function handleSignDelivery(
  payload: SignDeliveryPayload,
): Promise<SignDeliveryResult> {
  const privateKey = await getImportedPrivateKey(payload.privateKeyJwk);
  const bodyBuf = enc.encode(payload.body).buffer as ArrayBuffer;

  // 署名対象のヘッダは最小限に。fedify は Request に居る全 header を
  // 拾って `headers="..."` に並べて全部署名する。Cloudflare や HTTP
  // クライアント (Req) が `accept` / `user-agent` を勝手に再書き出し
  // すると、verify 側の `headers.get(name)` が違う値を返して
  // "Failed to verify the request signature." になる。
  // Mastodon と同じ最小セット `(request-target) content-type date
  // digest host` だけにしておけば、それ以外のヘッダを CF が触っても
  // 署名検証には影響しない。Accept / User-Agent は POST 時に
  // Elixir 側で追加するので情報は失われない。
  const request = new Request(payload.inbox, {
    method: "POST",
    headers: {
      "Content-Type": "application/activity+json",
    },
    body: payload.body,
  });

  // fedify は `options.spec` を見て cavage / 9421 を切り替える。
  // 引数名を間違えると静かに default (cavage-12) になるので注意。
  const spec: HttpMessageSignaturesSpec =
    payload.algorithm === "rfc9421"
      ? "rfc9421"
      : "draft-cavage-http-signatures-12";

  try {
    const signed = await signRequest(
      request,
      privateKey,
      new URL(payload.keyId),
      { spec, body: bodyBuf },
    );

    const outHeaders: Record<string, string> = {};
    signed.headers.forEach((v, k) => {
      outHeaders[k] = v;
    });

    // 自己検証 ─ 「Failed to verify the request signature」が消えない
    // ので、我々が作った署名を我々自身の公開鍵で verify できるかを
    // 確かめる。これが false なら署名そのものがおかしい(鍵 import の
    // 不整合、digest 計算の不整合、message 構築のずれ、など)。
    // true なら、署名は数学的に valid で、原因は受け手側 (cached key
    // が違うなど) にある。 [[fedify-401-diagnostic]]
    try {
      // private bits を落として public 部分だけ拾う。
      const priv = payload.privateKeyJwk as Record<string, unknown>;
      const publicOnly: Record<string, unknown> = {};
      for (const k of ["kty", "n", "e", "alg", "use", "kid"]) {
        if (k in priv) publicOnly[k] = priv[k];
      }
      const publicKey = await importJwk(
        publicOnly as Parameters<typeof importJwk>[0],
        "public",
      );

      // signed Request から (request-target) + 署名対象ヘッダで
      // message を組み直す。
      const sigHeader = signed.headers.get("signature") || "";
      const headersMatch = sigHeader.match(/headers="([^"]*)"/);
      const signedNames = headersMatch ? headersMatch[1].split(/\s+/g) : [];
      const url = new URL(payload.inbox);
      const message = signedNames
        .map((name) =>
          name === "(request-target)"
            ? `(request-target): post ${url.pathname}`
            : name === "host"
              ? `host: ${signed.headers.get("host") ?? url.host}`
              : `${name}: ${signed.headers.get(name) ?? ""}`,
        )
        .join("\n");

      const sigMatch = sigHeader.match(/signature="([^"]*)"/);
      const sigB64 = sigMatch ? sigMatch[1] : "";
      const sigBytes = Uint8Array.from(atob(sigB64), (c) => c.charCodeAt(0));

      const ok = await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5",
        publicKey,
        sigBytes,
        new TextEncoder().encode(message),
      );

      console.error(
        JSON.stringify({
          event: "sign.selftest",
          inbox: payload.inbox,
          ok,
          signed_names: signedNames,
          message_bytes: message.length,
        }),
      );
    } catch (vErr) {
      console.error(
        JSON.stringify({
          event: "sign.selftest.error",
          inbox: payload.inbox,
          error: vErr instanceof Error ? vErr.message : String(vErr),
        }),
      );
    }

    return { headers: outHeaders };
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    console.error(
      JSON.stringify({
        event: "sign.failed",
        inbox: payload.inbox,
        spec,
        error: detail,
      }),
    );
    throw new Error(`sign for ${payload.inbox} (spec=${spec}) failed: ${detail}`);
  }
}
