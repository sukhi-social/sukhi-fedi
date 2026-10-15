// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from "node:test";
import { expect } from "../test_support/expect.ts";
import {
  AS_PUBLIC_URL,
  followersUrlFor,
  mirrorAudience,
  resolveAudience,
} from "./addressing.ts";

const ACTOR = "https://watch.example/users/alice";

test("public audience: tos=[Public], ccs=[followers]", () => {
  const r = resolveAudience({ kind: "public", actor: ACTOR });
  expect(r.tos.map(String)).toEqual([AS_PUBLIC_URL.href]);
  expect(r.ccs.map(String)).toEqual([followersUrlFor(ACTOR).href]);
});

test("unlisted audience: tos=[followers], ccs=[Public]", () => {
  const r = resolveAudience({ kind: "unlisted", actor: ACTOR });
  expect(r.tos.map(String)).toEqual([followersUrlFor(ACTOR).href]);
  expect(r.ccs.map(String)).toEqual([AS_PUBLIC_URL.href]);
});

test("followers_only audience: tos=[followers], ccs=[]", () => {
  const r = resolveAudience({ kind: "followers_only", actor: ACTOR });
  expect(r.tos.map(String)).toEqual([followersUrlFor(ACTOR).href]);
  expect(r.ccs).toEqual([]);
});

test("direct audience: tos=recipients, ccs=[]", () => {
  const recipients = [
    "https://remote.example/users/bob",
    "https://other.example/users/carol",
  ];
  const r = resolveAudience({ kind: "direct", actors: recipients });
  expect(r.tos.map(String)).toEqual(recipients);
  expect(r.ccs).toEqual([]);
});

test("mirrorAudience points at the inner object", () => {
  const target = "https://remote.example/users/bob";
  const r = mirrorAudience(target);
  expect(r.tos.map(String)).toEqual([target]);
  expect(r.ccs).toEqual([]);
});

test("followersUrlFor builds <actor>/followers", () => {
  expect(followersUrlFor(ACTOR).href).toBe(`${ACTOR}/followers`);
});
