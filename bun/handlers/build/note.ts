import { Create, Note } from "@fedify/fedify/vocab";
import { nowInstant } from "../../fedify/temporal.ts";
import { humanNoteUrl, injectAttachments, injectMisskey, injectQuote, signAndSerialize, type AttachmentDescriptor, type SignedPayload } from "../../fedify/utils.ts";
import { resolveAudience } from "../../fedify/addressing.ts";

export interface BuildNotePayload extends SignedPayload {
  actor: string;
  content: string;
  recipientInboxes: string[];
  noteId: string;
  activityId: string;
  // AP id of a quoted note, when this note is a 引用ノート. Optional.
  quoteUrl?: string;
  // AP id of the note this replies to, so remote servers can thread it.
  inReplyToId?: string;
  // Media attachments, in gallery order. Optional.
  attachments?: AttachmentDescriptor[];
}

export interface BuildNoteResult {
  note: unknown;
  recipientInboxes: string[];
}

export async function handleBuildNote(
  payload: BuildNotePayload,
): Promise<BuildNoteResult> {
  const audience = resolveAudience({ kind: "public", actor: payload.actor });
  const humanUrl = humanNoteUrl(payload.actor, payload.noteId);

  const note = new Note({
    id: new URL(payload.noteId),
    attribution: new URL(payload.actor),
    content: payload.content,
    published: nowInstant(),
    tos: audience.tos,
    ccs: audience.ccs,
    ...(payload.inReplyToId ? { replyTarget: new URL(payload.inReplyToId) } : {}),
    // 人が読む頁のありか。`id` とは別もので、無いと受け取った側は
    // 「元の投稿を開く」の行き先を作れない。組めなければ足さない。
    ...(humanUrl ? { url: new URL(humanUrl) } : {}),
  });

  const create = new Create({
    id: new URL(payload.activityId),
    actor: new URL(payload.actor),
    object: note,
    tos: audience.tos,
    ccs: audience.ccs,
  });

  const noteJson = await signAndSerialize(payload, create);
  injectMisskey(noteJson, payload.content);
  injectQuote(noteJson, payload.quoteUrl);
  injectAttachments(noteJson, payload.attachments);

  return {
    note: noteJson,
    recipientInboxes: payload.recipientInboxes,
  };
}
