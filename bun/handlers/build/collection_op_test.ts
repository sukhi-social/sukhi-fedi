// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Locks in the Add/Remove translator shape used by featured-collection
// pin/unpin. Bug-prevention: a previous bug shipped Add/Remove without
// `target`, which Mastodon treated as no-ops (the receiver couldn't
// tell which collection to update).

import { test } from "node:test";
import { expect } from "../../test_support/expect.ts";
import { handleBuildAdd, handleBuildRemove } from "./collection_op.ts";
import { testCreds } from "./_test_helpers.ts";

const ACTOR = "https://watch.example/users/alice";
const FEATURED = `${ACTOR}/featured`;
const NOTE = `${ACTOR}/notes/123`;

test("Add(featured) sets object, target, and actor", async () => {
  const result = await handleBuildAdd({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    objectUri: NOTE,
    targetUri: FEATURED,
    activityId: `${ACTOR}/activities/add/1`,
    recipientInboxes: ["https://remote.example/inbox"],
  });

  const json = result.activity as Record<string, unknown>;
  expect(json["type"]).toBe("Add");
  expect(json["actor"]).toBe(ACTOR);
  expect(json["object"]).toBe(NOTE);
  expect(json["target"]).toBe(FEATURED);
  expect(json["id"]).toBe(`${ACTOR}/activities/add/1`);
});

test("Remove(featured) sets object, target, and actor", async () => {
  const result = await handleBuildRemove({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    objectUri: NOTE,
    targetUri: FEATURED,
    activityId: `${ACTOR}/activities/remove/1`,
    recipientInboxes: ["https://remote.example/inbox"],
  });

  const json = result.activity as Record<string, unknown>;
  expect(json["type"]).toBe("Remove");
  expect(json["actor"]).toBe(ACTOR);
  expect(json["object"]).toBe(NOTE);
  expect(json["target"]).toBe(FEATURED);
});

test("recipientInboxes flows through both builders verbatim", async () => {
  const inboxes = ["https://a.example/inbox", "https://b.example/inbox"];

  const addResult = await handleBuildAdd({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    objectUri: NOTE,
    targetUri: FEATURED,
    activityId: `${ACTOR}/activities/add/2`,
    recipientInboxes: inboxes,
  });

  const removeResult = await handleBuildRemove({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    objectUri: NOTE,
    targetUri: FEATURED,
    activityId: `${ACTOR}/activities/remove/2`,
    recipientInboxes: inboxes,
  });

  expect(addResult.recipientInboxes).toEqual(inboxes);
  expect(removeResult.recipientInboxes).toEqual(inboxes);
});
