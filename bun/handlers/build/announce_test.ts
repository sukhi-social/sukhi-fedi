// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Bug prevention: Announce previously shipped without to/cc (same
// shape as the 887afb9f/be3aa82 addressing regressions). This test
// locks in the expected public-boost addressing so the next repair
// to announce.ts can't regress visibility.

import { test } from "node:test";
import { expect } from "../../test_support/expect.ts";
import { handleBuildAnnounce } from "./announce.ts";
import { containsPublic, containsFollowers, testCreds } from "./_test_helpers.ts";

const ACTOR = "https://watch.example/users/alice";

test("Announce addresses Public on `to` and followers on `cc`", async () => {
  const result = await handleBuildAnnounce({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    object: "https://remote.example/notes/abc",
    activityId: `${ACTOR}/activities/announce/1`,
    recipientInboxes: [],
  });

  const json = result.announce as Record<string, unknown>;
  expect(containsPublic(json["to"])).toBe(true);
  expect(containsFollowers(json["cc"], ACTOR)).toBe(true);
});
