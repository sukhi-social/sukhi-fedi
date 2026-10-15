// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The few `expect(...)` matchers these tests use, on top of node:assert, so the
// suite runs under `node --test` and reads as it did under `bun test`.
// Add a matcher here when a test needs one; keep it to what is used.
import assert from "node:assert/strict";

type Matchers = {
  toBe(expected: unknown): void;
  toEqual(expected: unknown): void;
  toBeNull(): void;
  toBeDefined(): void;
  toBeUndefined(): void;
  toContain(item: unknown): void;
  toBeGreaterThan(n: number): void;
};

function matchers(actual: unknown, negate: boolean): Matchers {
  // Each matcher is a predicate plus a message; `not` flips the predicate.
  const check = (pass: boolean, message: string) =>
    assert.ok(negate ? !pass : pass, `${negate ? "not " : ""}${message}`);
  const show = (v: unknown) => JSON.stringify(v) ?? String(v);

  return {
    toBe: (expected) => {
      if (negate) assert.notStrictEqual(actual, expected);
      else assert.strictEqual(actual, expected);
    },
    toEqual: (expected) => {
      if (negate) assert.notDeepStrictEqual(actual, expected);
      else assert.deepStrictEqual(actual, expected);
    },
    toBeNull: () => check(actual === null, `expected ${show(actual)} toBeNull`),
    toBeDefined: () => check(actual !== undefined, `expected ${show(actual)} toBeDefined`),
    toBeUndefined: () => check(actual === undefined, `expected ${show(actual)} toBeUndefined`),
    toContain: (item) =>
      check(
        typeof actual === "string"
          ? actual.includes(String(item))
          : Array.isArray(actual) && actual.includes(item),
        `expected ${show(actual)} toContain ${show(item)}`,
      ),
    toBeGreaterThan: (n) =>
      check(typeof actual === "number" && actual > n, `expected ${show(actual)} > ${n}`),
  };
}

export function expect(actual: unknown): Matchers & { not: Matchers } {
  return { ...matchers(actual, false), not: matchers(actual, true) };
}
