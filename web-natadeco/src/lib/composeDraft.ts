// 書きかけの下書き。板ごとに localStorage へ ── タブを閉じても、
// クラッシュしても残る(セッションの中だけで消える sessionStorage は
// signup の下書きで使ったが、こっちはもっと長生きしてほしい)。

import { browser } from '$app/environment';

export type Draft = { title: string; text: string; titleKo: string; textKo: string };

const key = (slug: string) => `nd.draft.${slug}`;

export function loadDraft(slug: string): Draft | null {
  if (!browser) return null;
  const raw = localStorage.getItem(key(slug));
  if (!raw) return null;
  try {
    return JSON.parse(raw) as Draft;
  } catch {
    return null;
  }
}

export function saveDraft(slug: string, draft: Draft): void {
  if (!browser) return;
  if (!draft.title.trim() && !draft.text.trim() && !draft.titleKo.trim() && !draft.textKo.trim()) {
    clearDraft(slug);
    return;
  }
  localStorage.setItem(key(slug), JSON.stringify(draft));
}

export function clearDraft(slug: string): void {
  if (!browser) return;
  localStorage.removeItem(key(slug));
}

// 一度だけの、控えめなヒント。常設の説明にはしない ── 毎回同じ文が
// 出るのは、静かな UX の邪魔になるので。
const TIP_KEY = 'nd.seenComposeTip';

export function hasSeenComposeTip(): boolean {
  if (!browser) return true;
  return localStorage.getItem(TIP_KEY) === '1';
}

export function markComposeTipSeen(): void {
  if (!browser) return;
  localStorage.setItem(TIP_KEY, '1');
}
