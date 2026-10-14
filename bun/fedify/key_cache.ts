// SPDX-License-Identifier: AGPL-3.0-or-later
import type { webcrypto } from "node:crypto";
import { importJwk } from "@fedify/fedify";

// Node's typings declare `CryptoKey` as a value only; this is the type.
type CryptoKey = webcrypto.CryptoKey;

// Bounded FIFO cache of imported private CryptoKeys. Key is the stable
// fingerprint of the JWK so two deliveries signed by the same actor reuse
// the same `CryptoKey` instead of paying for `SubtleCrypto.importKey` each
// time. FIFO eviction is cheap and close enough to LRU for this workload
// (local actor set is small; fan-out re-uses a handful of keys repeatedly).

export type JwkInput = Parameters<typeof importJwk>[0];

const MAX_ENTRIES = 256;
const cache = new Map<string, CryptoKey>();

function fingerprint(jwk: JwkInput): string {
  const sorted: Record<string, unknown> = {};
  for (const k of Object.keys(jwk).sort()) {
    sorted[k] = (jwk as Record<string, unknown>)[k];
  }
  return JSON.stringify(sorted);
}

export async function getImportedPrivateKey(jwk: JwkInput): Promise<CryptoKey> {
  const fp = fingerprint(jwk);
  const hit = cache.get(fp);
  if (hit) {
    // Refresh recency by re-inserting — Map iteration order is insertion order.
    cache.delete(fp);
    cache.set(fp, hit);
    return hit;
  }

  const key = await importJwk(jwk, "private");

  if (cache.size >= MAX_ENTRIES) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(fp, key);
  return key;
}

// Test-only helpers
export function _cacheSize(): number {
  return cache.size;
}

export function _cacheClear(): void {
  cache.clear();
}
