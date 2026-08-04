// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 人が読む頁のありか(AP の `url`)。
//
// `id` は機械の識別子で、`url` は「見に行くならここ」── 別のものなのに、
// こちらは `id` しか出していなかった。受け取った側は「元の投稿を開く」の
// 行き先を作れないまま、押しても何も起きない釦を持つことになる。
//
// まちがった行き先を渡すのは、渡さないより悪い。だから組めないときは
// null で、何も足さない。
import { test, expect } from "bun:test";
import { humanNoteUrl } from "./utils.ts";

const ACTOR = "https://sukhi.f3liz.casa/users/shiro_mudita";
const NOTE = "https://sukhi.f3liz.casa/users/shiro_mudita/notes/5353596300850774";

test("actor と note id から、人の頁を組む", () => {
  expect(humanNoteUrl(ACTOR, NOTE)).toBe(
    "https://sukhi.f3liz.casa/@shiro_mudita/5353596300850774",
  );
});

test("host が違ったら、組まない", () => {
  // 自分の投稿にほかの家の住所を書いて配るのは、いちばんまずい。
  expect(humanNoteUrl(ACTOR, "https://elsewhere.example/users/x/notes/1")).toBeNull();
});

test("actor の形が違ったら、組まない", () => {
  expect(humanNoteUrl("https://sukhi.f3liz.casa/@shiro_mudita", NOTE)).toBeNull();
  expect(humanNoteUrl("https://sukhi.f3liz.casa/users/a/b", NOTE)).toBeNull();
});

test("note の形が違ったら、組まない", () => {
  expect(humanNoteUrl(ACTOR, "https://sukhi.f3liz.casa/users/shiro_mudita")).toBeNull();
});

test("URL でないものが来ても、転ばない", () => {
  for (const junk of ["", "なにか", "not a url", "//x"]) {
    expect(humanNoteUrl(junk, NOTE)).toBeNull();
    expect(humanNoteUrl(ACTOR, junk)).toBeNull();
  }
});

test("返すのは、そのまま URL として使える形", () => {
  const out = humanNoteUrl(ACTOR, NOTE);
  expect(out).not.toBeNull();
  expect(new URL(out!).href).toBe(out);
});
