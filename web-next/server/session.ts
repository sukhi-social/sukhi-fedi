// SPDX-License-Identifier: AGPL-3.0-or-later
// 郵便局の、預かりもの。
//
// SPA では、アクセストークンをブラウザの localStorage に持っていた。MPA では、ブラウザには
// 乱数の札(sukhi_sid)だけを渡し、トークンはここ(サーバ)に置く。XSS があっても、盗めるのは札。
//
// 置き場は、メモリ + data/sessions.json(すこし待ってから書く)。再起動しても、入ったまま。

import { randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, renameSync } from 'node:fs';
import { config } from './config.ts';
import type { Account, TokenSet } from './types.ts';

export type Session = {
  id: string;
  token?: TokenSet;
  // verify_credentials のひかえ。ナビのアバターと「これは自分の投稿か」に使う。
  me?: Account;
  oauthState?: string;
  // ログイン後に戻る先(/oauth/authorize から弾かれて来たとき)。
  next?: string;
  // 次の一枚の頁にだけ見せる、ひとこと。
  flash?: { kind: 'notice' | 'error'; text: string };
  // 預かっている予約投稿の「手元のひかえ」。gateway が一覧を返さないときの代わり。
  pending?: { id: string; text: string; at: string }[];
};

const file = `${config.dataDir}sessions.json`;
const sessions = new Map<string, Session>();

try {
  const saved = JSON.parse(readFileSync(file, 'utf8')) as Session[];
  for (const s of saved) sessions.set(s.id, s);
} catch {
  // はじめて、または読めなかった。空から。
}

let timer: ReturnType<typeof setTimeout> | null = null;
function persist(): void {
  if (timer) return;
  timer = setTimeout(() => {
    timer = null;
    try {
      mkdirSync(config.dataDir, { recursive: true });
      const tmp = `${file}.tmp`;
      writeFileSync(tmp, JSON.stringify([...sessions.values()]), { mode: 0o600 });
      renameSync(tmp, file);
    } catch {
      // 書けなくても、メモリの中では続く。
    }
  }, 500);
  timer.unref();
}

export function getSession(id: string | undefined): Session | undefined {
  return id ? sessions.get(id) : undefined;
}

export function createSession(): Session {
  const s: Session = { id: randomBytes(24).toString('base64url') };
  sessions.set(s.id, s);
  persist();
  return s;
}

export function saveSession(s: Session): void {
  sessions.set(s.id, s);
  persist();
}

export function destroySession(id: string): void {
  sessions.delete(id);
  persist();
}
