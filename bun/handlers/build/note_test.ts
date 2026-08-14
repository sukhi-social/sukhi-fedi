// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression tests for the 887afb9f bug: Create(Note) shipped without
// to/cc, and iceshrimp/Mastodon dropped the note from timelines. These
// tests assert the activity *and* the inner Note both carry the
// expected audience shape. Run on every PR.

import { test, expect } from "bun:test";
import { handleBuildNote } from "./note.ts";
import { containsPublic, containsFollowers, testCreds } from "./_test_helpers.ts";

const ACTOR = "https://watch.example/users/alice";

test("Create(Note) addresses Public on `to` and followers on `cc` — activity", async () => {
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "hi",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/1`,
    activityId: `${ACTOR}/activities/create/1`,
  });

  const json = result.note as Record<string, unknown>;
  expect(containsPublic(json["to"])).toBe(true);
  expect(containsFollowers(json["cc"], ACTOR)).toBe(true);
});

test("Create(Note) addresses Public on `to` and followers on `cc` — inner Note object", async () => {
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "hi",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/2`,
    activityId: `${ACTOR}/activities/create/2`,
  });

  const json = result.note as Record<string, unknown>;
  const inner = json["object"] as Record<string, unknown>;
  expect(containsPublic(inner["to"])).toBe(true);
  expect(containsFollowers(inner["cc"], ACTOR)).toBe(true);
});

test("Create(Note) includes _misskey_content on the inner Note", async () => {
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "hello <b>world</b>",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/3`,
    activityId: `${ACTOR}/activities/create/3`,
  });
  const inner = (result.note as Record<string, unknown>)["object"] as Record<string, unknown>;
  expect(inner["_misskey_content"]).toBe("hello <b>world</b>");
});

test("Create(Note) carries quoteUrl + _misskey_quote when a quote is set", async () => {
  const QUOTED = "https://remote.example/notes/orig";
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "quoting",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/4`,
    activityId: `${ACTOR}/activities/create/4`,
    quoteUrl: QUOTED,
  });
  const inner = (result.note as Record<string, unknown>)["object"] as Record<string, unknown>;
  expect(inner["quoteUrl"]).toBe(QUOTED);
  expect(inner["_misskey_quote"]).toBe(QUOTED);
});

test("Create(Note) omits quote fields when there is no quote", async () => {
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "no quote",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/5`,
    activityId: `${ACTOR}/activities/create/5`,
  });
  const inner = (result.note as Record<string, unknown>)["object"] as Record<string, unknown>;
  expect(inner["quoteUrl"]).toBeUndefined();
});

test("Create(Note) emits a FEP-e232 quote tag Link alongside the legacy fields", async () => {
  const QUOTED = "https://remote.example/notes/orig";
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "quoting",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/6`,
    activityId: `${ACTOR}/activities/create/6`,
    quoteUrl: QUOTED,
  });
  const inner = (result.note as Record<string, unknown>)["object"] as Record<string, unknown>;
  const tags = (Array.isArray(inner["tag"]) ? inner["tag"] : [inner["tag"]]) as Record<string, unknown>[];
  const link = tags.find((t) => t && t["type"] === "Link" && t["href"] === QUOTED);
  expect(link).toBeDefined();
  expect(String(link!["rel"])).toContain("_misskey_quote");
});

test("Create(Note) carries media as `attachment` Document objects on the inner Note", async () => {
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "with a picture",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/8`,
    activityId: `${ACTOR}/activities/create/8`,
    attachments: [
      { url: "https://watch.example/uploads/1/abc.png", mediaType: "image/png", name: "alt", width: 640, height: 480 },
    ],
  });
  const inner = (result.note as Record<string, unknown>)["object"] as Record<string, unknown>;
  const att = inner["attachment"] as Record<string, unknown>[];
  expect(Array.isArray(att)).toBe(true);
  expect(att[0]["type"]).toBe("Document");
  expect(att[0]["url"]).toBe("https://watch.example/uploads/1/abc.png");
  expect(att[0]["mediaType"]).toBe("image/png");
  expect(att[0]["name"]).toBe("alt");
  expect(att[0]["width"]).toBe(640);
});

test("Create(Note) omits `attachment` when there is no media", async () => {
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "text only",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/9`,
    activityId: `${ACTOR}/activities/create/9`,
  });
  const inner = (result.note as Record<string, unknown>)["object"] as Record<string, unknown>;
  expect(inner["attachment"]).toBeUndefined();
});

test("Create(Note) carries inReplyTo on the inner Note when replying", async () => {
  const PARENT = "https://remote.example/notes/parent";
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "a reply",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/7`,
    activityId: `${ACTOR}/activities/create/7`,
    inReplyToId: PARENT,
  });
  const inner = (result.note as Record<string, unknown>)["object"] as Record<string, unknown>;
  expect(inner["inReplyTo"]).toBe(PARENT);
});

test("Create(Note) injects Emoji tags into tag array for custom emojis", async () => {
  const result = await handleBuildNote({
    ...await testCreds(ACTOR),
    actor: ACTOR,
    content: "hello :blobcat:",
    recipientInboxes: [],
    noteId: `${ACTOR}/notes/10`,
    activityId: `${ACTOR}/activities/create/10`,
    emojis: [
      { shortcode: "blobcat", url: "https://watch.example/emojis/blobcat.png" },
    ],
  });
  const inner = (result.note as Record<string, unknown>)["object"] as Record<string, unknown>;
  const tags = (Array.isArray(inner["tag"]) ? inner["tag"] : [inner["tag"]]) as Record<string, unknown>[];
  const emojiTag = tags.find((t) => t && t["type"] === "Emoji");
  expect(emojiTag).toBeDefined();
  expect(emojiTag!["name"]).toBe(":blobcat:");
  expect((emojiTag!["icon"] as Record<string, unknown>)["url"]).toBe("https://watch.example/emojis/blobcat.png");
});
