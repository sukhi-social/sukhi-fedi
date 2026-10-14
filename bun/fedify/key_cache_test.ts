// SPDX-License-Identifier: AGPL-3.0-or-later
import { test, beforeEach } from "node:test";
import { expect } from "../test_support/expect.ts";
import { generateCryptoKeyPair, exportJwk } from "@fedify/fedify";
import { getImportedPrivateKey, _cacheSize, _cacheClear, type JwkInput } from "./key_cache.ts";

beforeEach(() => {
  _cacheClear();
});

test("key cache returns identical CryptoKey for the same JWK", async () => {
  const { privateKey } = await generateCryptoKeyPair("Ed25519");
  const jwk = (await exportJwk(privateKey)) as JwkInput;

  const first = await getImportedPrivateKey(jwk);
  const second = await getImportedPrivateKey(jwk);

  expect(second).toBe(first);
  expect(_cacheSize()).toBe(1);
});

test("key cache separates distinct JWKs", async () => {
  const a = await generateCryptoKeyPair("Ed25519");
  const b = await generateCryptoKeyPair("Ed25519");
  const jwkA = (await exportJwk(a.privateKey)) as JwkInput;
  const jwkB = (await exportJwk(b.privateKey)) as JwkInput;

  const keyA = await getImportedPrivateKey(jwkA);
  const keyB = await getImportedPrivateKey(jwkB);

  expect(keyA).not.toBe(keyB);
  expect(_cacheSize()).toBe(2);
});

test("key cache is key-order insensitive", async () => {
  const { privateKey } = await generateCryptoKeyPair("Ed25519");
  const jwk = (await exportJwk(privateKey)) as JwkInput;

  // Rebuild the JWK with keys in a different insertion order.
  const reshuffled: JwkInput = Object.keys(jwk)
    .sort()
    .reverse()
    .reduce((acc, k) => {
      (acc as Record<string, unknown>)[k] = (jwk as Record<string, unknown>)[k];
      return acc;
    }, {} as JwkInput);

  const first = await getImportedPrivateKey(jwk);
  const second = await getImportedPrivateKey(reshuffled);

  expect(second).toBe(first);
  expect(_cacheSize()).toBe(1);
});
