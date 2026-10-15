// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Locks in the emoji-reaction builder's payload shape: a Like with
// `content` carrying the emoji, and an optional Emoji entry in `tag`
// when the reaction is a custom shortcode.
//
// We send Like (not EmojiReact) so Mastodon peers downgrade to plain
// likes instead of dropping the activity.

import { test } from "node:test";
import { expect } from "../../test_support/expect.ts";
import { handleBuildEmojiReact } from "./emoji_react.ts";
import { testCreds } from "./_test_helpers.ts";

const ACTOR = "https://watch.example/users/alice";
const NOTE = "https://remote.example/notes/abc";

test("emoji_react produces a Like with the emoji in content", async () => {
  const result = await handleBuildEmojiReact({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    object: NOTE,
    content: "🦊",
    activityId: `${ACTOR}/likes/1`,
    recipientInboxes: ["https://remote.example/users/bob/inbox"],
  });

  const like = result.emojiReact as Record<string, unknown>;
  expect(like["type"]).toBe("Like");
  expect(like["actor"]).toBe(ACTOR);
  expect(like["object"]).toBe(NOTE);
  expect(like["content"]).toBe("🦊");
});

test("emoji_react accepts a :shortcode: with a tag entry", async () => {
  const result = await handleBuildEmojiReact({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    object: NOTE,
    content: ":blobcat:",
    tag: {
      name: ":blobcat:",
      url: "https://watch.example/emoji/blobcat.png",
    },
    activityId: `${ACTOR}/likes/2`,
    recipientInboxes: [],
  });

  const like = result.emojiReact as Record<string, unknown>;
  expect(like["type"]).toBe("Like");
  expect(like["content"]).toBe(":blobcat:");

  const tag = like["tag"];
  expect(tag).toBeDefined();
});

test("emoji_react passes recipientInboxes through verbatim", async () => {
  const inboxes = ["https://remote.example/users/bob/inbox"];
  const result = await handleBuildEmojiReact({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    object: NOTE,
    content: "👍",
    activityId: `${ACTOR}/likes/3`,
    recipientInboxes: inboxes,
  });

  expect(result.recipientInboxes).toEqual(inboxes);
});
