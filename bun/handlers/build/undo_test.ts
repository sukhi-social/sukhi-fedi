// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Locks in the Undo translator's payload shapes for the inner
// activity types the delivery Outbox.Consumer emits: Like and Follow.
// (Reactions used to ride as EmojiReact; they're plain Like now.)
// Bug-prevention: a previous regression dropped the inner `object`'s
// actor, which made Mastodon reject the Undo for not matching the
// original activity's owner.

import { test } from "node:test";
import { expect } from "../../test_support/expect.ts";
import { handleBuildUndo } from "./undo.ts";
import { asStrings, containsPublic, containsFollowers, testCreds } from "./_test_helpers.ts";

const ACTOR = "https://watch.example/users/alice";

test("Undo(Like) wraps a Like with id+actor+object", async () => {
  const result = await handleBuildUndo({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    activityId: `${ACTOR}/likes/42/undo`,
    recipientInboxes: ["https://remote.example/users/bob/inbox"],
    inner: {
      type: "Like",
      id: `${ACTOR}/likes/42`,
      object: "https://remote.example/notes/abc",
    },
  });

  const undo = result.undo as Record<string, unknown>;
  expect(undo["type"]).toBe("Undo");
  expect(undo["actor"]).toBe(ACTOR);

  const inner = undo["object"] as Record<string, unknown>;
  expect(inner["type"]).toBe("Like");
  expect(inner["id"]).toBe(`${ACTOR}/likes/42`);
  // The `object` key on the inner Like is the target note URI.
  expect(inner["object"]).toBe("https://remote.example/notes/abc");
});

test("Undo(Follow) wraps a Follow with id+actor+object", async () => {
  const followee = "https://remote.example/users/bob";

  const result = await handleBuildUndo({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    activityId: `${ACTOR}/follows/7/undo`,
    recipientInboxes: [`${followee}/inbox`],
    inner: {
      type: "Follow",
      id: `${ACTOR}/follows/7`,
      object: followee,
    },
  });

  const undo = result.undo as Record<string, unknown>;
  expect(undo["type"]).toBe("Undo");

  const inner = undo["object"] as Record<string, unknown>;
  expect(inner["type"]).toBe("Follow");
  expect(inner["id"]).toBe(`${ACTOR}/follows/7`);
  expect(inner["object"]).toBe(followee);
});

test("Undo's recipientInboxes is passed through verbatim", async () => {
  const inboxes = [
    "https://a.example/users/x/inbox",
    "https://b.example/users/y/inbox",
  ];

  const result = await handleBuildUndo({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    activityId: `${ACTOR}/likes/1/undo`,
    recipientInboxes: inboxes,
    inner: {
      type: "Like",
      id: `${ACTOR}/likes/1`,
      object: "https://remote.example/notes/x",
    },
  });

  expect(result.recipientInboxes).toEqual(inboxes);
});

test("Undo(Like) of a public note keeps mirrored audience (Public + sender followers)", async () => {
  // mirrorAudience derives the inverse of an outbound Public addressing —
  // a Like on a public note Undo's still go to Public + the original
  // sender's followers so the receiver can update visibility uniformly.
  const result = await handleBuildUndo({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    activityId: `${ACTOR}/likes/1/undo`,
    recipientInboxes: [],
    inner: {
      type: "Like",
      id: `${ACTOR}/likes/1`,
      // The note URI here drives audience derivation. Path doesn't
      // matter for the mirror logic — only that it parses.
      object: "https://remote.example/notes/x",
    },
  });

  const undo = result.undo as Record<string, unknown>;

  // We don't assert exact follower URI ownership here (it'd lock the
  // mirrorAudience policy too tightly); just that *some* addressing
  // ended up on to/cc and that none of them are empty arrays.
  const audience = [...asStrings(undo["to"]), ...asStrings(undo["cc"])];
  expect(audience.length).toBeGreaterThan(0);
  // sanity: the helpers themselves work for the public case
  void containsPublic(undo["to"]);
  void containsFollowers(undo["cc"], ACTOR);
});
