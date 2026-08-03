// 書きかけのノートを、この端末に覚えておく。ナビゲーションや
// リロードで消えてしまわないように。ログインしていれば、サーバにも
// そっと同期して、ほかの端末から続きを書けるようにする。
//
//   sf.compose_draft — { text, spoiler, useSpoiler, sensitive, visibility }
//
// この端末のローカルが、オフラインでの正本。サーバはその写しで、
// 開いたときに静かに突き合わせる(reconcile)── トーストもバッジも
// 出さない。サーバの下書きは口座ごとに一つだけで、連合はしない
// (private/never federated)。
//
// media は覚えない。アップロード済みの id はサーバ側で期限切れ・
// GC されるので、戻しても切れた id を指すだけ ─ 文字だけ戻す。
// 返信の下書きは覚えない(トップの新規ノート専用)。
import { browser } from '$app/environment';
import {
  type Visibility,
  type ServerDraft,
  getServerDraft,
  putServerDraft,
  deleteServerDraft
} from './api';
import { isLoggedIn } from './auth';

const DRAFT_KEY = 'sf.compose_draft';

export type ComposeDraft = {
  text: string;
  spoiler: string;
  useSpoiler: boolean;
  sensitive: boolean;
  visibility: Visibility;
};

// 「中身が無い」の唯一の判定。ローカル/サーバ両方の下書きが通る
// (text と spoiler だけ見るので、updated_at 付きのサーバ版もそのまま)。
function isEmpty(d: { text: string; spoiler: string }): boolean {
  return d.text.trim() === '' && d.spoiler.trim() === '';
}

export function saveComposeDraft(d: ComposeDraft): void {
  if (!browser) return;
  localStorage.setItem(DRAFT_KEY, JSON.stringify(d));
  // ログインしていれば、サーバの写しも更新する(last-write)。失敗は
  // 黙って飲む ─ オフラインでもローカルは残るので、下書きは消えない。
  if (isLoggedIn()) void putServerDraft(d).catch(() => {});
}

export function loadComposeDraft(): ComposeDraft | null {
  if (!browser) return null;
  const raw = localStorage.getItem(DRAFT_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as ComposeDraft;
  } catch {
    return null;
  }
}

export function clearComposeDraft(): void {
  if (!browser) return;
  localStorage.removeItem(DRAFT_KEY);
  // 送れた / 捨てたとき、サーバの写しも畳む。これが prune-on-post。
  if (isLoggedIn()) void deleteServerDraft().catch(() => {});
}

// ── DM の書きかけ ────────────────────────────────────────────────────────
//
//   sf.dm_draft.<conversation_id> — 本文だけ
//
// DM は全部が返信なので、上の下書き(トップの新規ノート専用)には乗らず、
// 画面を離れると書きかけが消えていた。会話ごとに、この端末だけで覚える。
//
// **サーバとは同期しない。** 上の写しは「アカウントに下書きは一つ」という
// 前提で組まれていて、会話ごとの書きかけはそこに収まらない。それに、DM の
// 書きかけを別の端末へ運ぶかどうかは、それ自体が判断で、下書きのついでに
// 決めることではない。
//
// 覚えるのは本文だけ。DM では可視性も注意書きも動かないので、ほかに持つ
// ものが無い。

const DM_DRAFT_PREFIX = 'sf.dm_draft.';

export function saveDmDraft(conversationId: string, text: string): void {
  if (!browser) return;
  localStorage.setItem(DM_DRAFT_PREFIX + conversationId, text);
}

export function loadDmDraft(conversationId: string): string {
  if (!browser) return '';
  return localStorage.getItem(DM_DRAFT_PREFIX + conversationId) ?? '';
}

export function clearDmDraft(conversationId: string): void {
  if (!browser) return;
  localStorage.removeItem(DM_DRAFT_PREFIX + conversationId);
}

// 開いたときに、ローカルとサーバの下書きを静かに突き合わせる。この
// 端末のローカルが正本なので、ローカルに中身があればそれを優先し、
// サーバへ写しを揃える(別端末の古い写しに上書きされない)。ローカル
// が空のときだけ、サーバの下書きを迎え入れる(別端末の続き)。返り値は
// 復元すべき下書き、なければ null。ログインしていない/通信できない
// ときは、ローカルをそのまま返す ─ 何も起きなかったかのように。
export async function reconcileComposeDraft(): Promise<ComposeDraft | null> {
  const local = loadComposeDraft();
  if (!browser || !isLoggedIn()) return local;

  let server: ServerDraft | null;
  try {
    server = await getServerDraft();
  } catch {
    return local;
  }

  if (local && !isEmpty(local)) {
    // ローカルが正本。サーバの写しを揃えてから、ローカルを返す。
    void putServerDraft(local).catch(() => {});
    return local;
  }

  if (server && !isEmpty(server)) {
    const adopted: ComposeDraft = {
      text: server.text,
      spoiler: server.spoiler,
      useSpoiler: server.useSpoiler,
      sensitive: server.sensitive,
      visibility: server.visibility
    };
    localStorage.setItem(DRAFT_KEY, JSON.stringify(adopted));
    return adopted;
  }

  return local;
}
