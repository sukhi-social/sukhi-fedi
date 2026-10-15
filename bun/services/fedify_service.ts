// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Fedify NATS Micro service.
//
// Exposes six endpoints to Elixir via NATS request/reply:
//   - fedify.ping.v1      : health check / liveness probe
//   - fedify.translate.v1 : build ActivityPub JSON-LD from a domain object
//   - fedify.sign.v1      : HTTP-Signature an outbound request envelope
//   - fedify.verify.v1    : verify an incoming signed HTTP request
//   - fedify.inbox.v1     : parse an incoming activity into an instruction
//   - fedify.fetch.v1     : fetch a remote AP document (HTTP-signed)
//
// Multiple replicas can run in parallel. NATS Micro queue-groups them
// automatically via `queue: "fedify-workers"` so load is balanced across
// instances.
//
// Running: NATS_URL=nats://localhost:4222 node --import tsx services/fedify_service.ts
// Testing: nats --server nats://localhost:4222 req fedify.ping.v1 hello

import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { connect, type NatsConnection } from "nats";
import { Svcm, type Service } from "@nats-io/services";

import { handleBuildNote } from "../handlers/build/note.ts";
import { handleBuildFollow } from "../handlers/build/follow.ts";
import { handleBuildAnnounce } from "../handlers/build/announce.ts";
import { handleBuildDm } from "../handlers/build/dm.ts";
import { handleBuildAdd, handleBuildRemove } from "../handlers/build/collection_op.ts";
import { handleBuildLike } from "../handlers/build/like.ts";
import { handleBuildEmojiReact } from "../handlers/build/emoji_react.ts";
import { handleBuildUndo } from "../handlers/build/undo.ts";
import { handleBuildDelete } from "../handlers/build/delete.ts";
import { handleSignDelivery } from "../handlers/sign_delivery.ts";
import { handleVerify } from "../handlers/verify.ts";
import { handleInbox } from "../handlers/inbox.ts";
import { handleFetch } from "../handlers/fetch.ts";
import { mergedTranslators } from "../addons/loader.ts";
import type { TranslateHandler } from "../addons/types.ts";

type AnyMsg = any;

const dec = new TextDecoder();
const enc = new TextEncoder();

// Core `translate.v1` dispatch table — ActivityPub-ish domain object
// types built into every deployment. Addons contribute additional
// namespaced keys (`<addon_id>.<type>`) via their manifest.
//
// `dm` is staged for the upcoming direct-message send path (see
// OPEN_QUESTIONS Q4); nothing requests it from Elixir yet. `emoji_react`
// is likewise staged — the gateway can emit `sns.outbox.reaction.created`
// but no local trigger creates a custom reaction until the Misskey
// client API ships.
const CORE_TRANSLATORS: Record<string, TranslateHandler> = {
  note: handleBuildNote as TranslateHandler,
  follow: handleBuildFollow as TranslateHandler,
  announce: handleBuildAnnounce as TranslateHandler,
  dm: handleBuildDm as TranslateHandler,
  add: handleBuildAdd as TranslateHandler,
  remove: handleBuildRemove as TranslateHandler,
  like: handleBuildLike as TranslateHandler,
  emoji_react: handleBuildEmojiReact as TranslateHandler,
  undo: handleBuildUndo as TranslateHandler,
  delete: handleBuildDelete as TranslateHandler,
};

const TRANSLATORS: Record<string, TranslateHandler> = mergedTranslators(CORE_TRANSLATORS);

function respondOk(msg: AnyMsg, data: unknown) {
  msg.respond(enc.encode(JSON.stringify({ ok: true, data })));
}

function respondError(msg: AnyMsg, error: string) {
  msg.respond(enc.encode(JSON.stringify({ ok: false, error })));
}

async function handleTranslate(msg: AnyMsg) {
  try {
    const body = JSON.parse(dec.decode(msg.data)) as {
      object_type: string;
      payload: unknown;
    };
    const handler = TRANSLATORS[body.object_type];
    if (!handler) {
      respondError(msg, `unknown object_type: ${body.object_type}`);
      return;
    }
    const result = await handler(body.payload);
    respondOk(msg, result);
  } catch (e) {
    respondError(msg, e instanceof Error ? e.message : String(e));
  }
}

async function handleSign(msg: AnyMsg) {
  try {
    const body = JSON.parse(dec.decode(msg.data));
    const result = await handleSignDelivery(body);
    respondOk(msg, result);
  } catch (e) {
    respondError(msg, e instanceof Error ? e.message : String(e));
  }
}

async function handleVerifyMicro(msg: AnyMsg) {
  try {
    const body = JSON.parse(dec.decode(msg.data));
    const result = await handleVerify(body);
    respondOk(msg, result);
  } catch (e) {
    respondError(msg, e instanceof Error ? e.message : String(e));
  }
}

async function handleInboxMicro(msg: AnyMsg) {
  try {
    const body = JSON.parse(dec.decode(msg.data));
    const result = await handleInbox(body);
    respondOk(msg, result);
  } catch (e) {
    respondError(msg, e instanceof Error ? e.message : String(e));
  }
}

async function handleFetchMicro(msg: AnyMsg) {
  try {
    const body = JSON.parse(dec.decode(msg.data));
    const result = await handleFetch(body);
    respondOk(msg, result);
  } catch (e) {
    respondError(msg, e instanceof Error ? e.message : String(e));
  }
}

export interface StartedService {
  service: Service;
  nc: NatsConnection;
  stop: () => Promise<void>;
}

export async function startFedifyService(
  natsUrl: string = "nats://localhost:4222",
): Promise<StartedService> {
  const nc = await connect({ servers: natsUrl });

  const svcm = new Svcm(nc);
  const service = await svcm.add({
    name: "fedify",
    version: "0.2.0",
    description: "sukhi-fedi Fedify translator / signer / verifier",
    queue: "fedify-workers",
  });

  const grp = service.addGroup("fedify");

  // @nats-io/services forbids dots in endpoint names (they're tokens, not
  // subjects). Pass `subject` explicitly so the external subject stays
  // `fedify.<op>.v1` — the Elixir client talks to these subjects directly.
  grp.addEndpoint("ping_v1", {
    subject: "ping.v1",
    handler: (err, msg) => {
      if (err) {
        service.stop(err as Error);
        return;
      }
      msg.respond(msg.data);
    },
  });

  grp.addEndpoint("translate_v1", {
    subject: "translate.v1",
    handler: (err, msg) => {
      if (err) return service.stop(err as Error);
      void handleTranslate(msg);
    },
  });

  grp.addEndpoint("sign_v1", {
    subject: "sign.v1",
    handler: (err, msg) => {
      if (err) return service.stop(err as Error);
      void handleSign(msg);
    },
  });

  grp.addEndpoint("verify_v1", {
    subject: "verify.v1",
    handler: (err, msg) => {
      if (err) return service.stop(err as Error);
      void handleVerifyMicro(msg);
    },
  });

  grp.addEndpoint("inbox_v1", {
    subject: "inbox.v1",
    handler: (err, msg) => {
      if (err) return service.stop(err as Error);
      void handleInboxMicro(msg);
    },
  });

  grp.addEndpoint("fetch_v1", {
    subject: "fetch.v1",
    handler: (err, msg) => {
      if (err) return service.stop(err as Error);
      void handleFetchMicro(msg);
    },
  });

  const stop = async () => {
    await service.stop();
    await nc.drain();
  };

  return { service, nc, stop };
}

// Run as `node --import tsx services/fedify_service.ts` (not when imported by a test).
if (resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  const url = process.env.NATS_URL ?? "nats://localhost:4222";
  const { service, stop } = await startFedifyService(url);

  const shutdown = async () => {
    console.log("shutting down fedify service...");
    await stop();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  const info = service.info();
  console.log("fedify service started");
  console.log(`  name:      ${info.name}`);
  console.log(`  version:   ${info.version}`);
  console.log(`  id:        ${info.id}`);
  console.log(`  queue:     fedify-workers`);
  console.log(`  endpoints: fedify.{ping,translate,sign,verify,inbox,fetch}.v1`);
  console.log(`  NATS URL:  ${url}`);

  // Block forever; signal handler takes care of shutdown.
  await new Promise(() => {});
}
