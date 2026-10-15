// 絵文字検索・インデックスと最近使用した絵文字の管理。
//
// カスタム絵文字（API経由）だけを対象に、短コード・エイリアス（別名）・
// カテゴリ名から候補を検索・ランキングします。Unicode 絵文字は端末のキーボードの仕事で、ここには置きません。

import type { Emoji } from './api';

export interface AutocompleteEmoji {
  shortcode: string;
  url?: string;
  staticUrl?: string;
  category?: string;
  aliases: string[];
}

const RECENT_STORAGE_KEY = 'sukhi_recent_emojis';
const MAX_RECENTS = 30;

let customEmojiCache: AutocompleteEmoji[] = [];

/**
 * カスタム絵文字リストをメモリキャッシュに登録する。
 */
export function setCustomEmojisCache(emojis: (Emoji | AutocompleteEmoji)[]): void {
  customEmojiCache = (emojis || [])
    .filter((e) => ('visible_in_picker' in e ? e.visible_in_picker !== false : true))
    .map((e) => {
      const aliases = 'aliases' in e && Array.isArray(e.aliases) ? e.aliases : [];
      return {
        shortcode: e.shortcode,
        url: 'url' in e ? e.url : undefined,
        staticUrl: 'static_url' in e ? e.static_url : ('staticUrl' in e ? e.staticUrl : undefined),
        category: e.category || undefined,
        aliases
      };
    });
}

/**
 * 現在キャッシュされているカスタム絵文字を取得する。
 */
export function getCustomEmojisCache(): AutocompleteEmoji[] {
  return customEmojiCache;
}

function getStorage(): Storage | null {
  if (typeof window !== 'undefined' && window.localStorage) return window.localStorage;
  if (typeof localStorage !== 'undefined') return localStorage;
  return null;
}

/**
 * 最近使用した絵文字の一覧（LocalStorage）を取得する。
 */
export function getRecentEmojis(): string[] {
  const storage = getStorage();
  if (!storage) return [];
  try {
    const raw = storage.getItem(RECENT_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/**
 * 最近使用した絵文字を記録する。
 */
export function recordRecentEmoji(code: string): void {
  const storage = getStorage();
  if (!code || !storage) return;
  const clean = code.replace(/^:|:$/g, '');
  if (!clean) return;

  try {
    const current = getRecentEmojis();
    const updated = [clean, ...current.filter((c) => c !== clean && c !== `:${clean}:`)].slice(0, MAX_RECENTS);
    storage.setItem(RECENT_STORAGE_KEY, JSON.stringify(updated));
  } catch {}
}

/**
 * 最近使用した絵文字の履歴を消去する（テストやリセット用）。
 */
export function clearRecentEmojis(): void {
  const storage = getStorage();
  if (!storage) return;
  try {
    storage.removeItem(RECENT_STORAGE_KEY);
  } catch {}
}

/**
 * 短コード・エイリアス・カテゴリ・最近の使用履歴から絵文字候補を検索・ランキングする。
 */
export function searchEmojis(query: string, limit = 8): AutocompleteEmoji[] {
  const allEmojis = customEmojiCache;
  const recents = getRecentEmojis();

  const q = query.trim().toLowerCase().replace(/^:|:$/g, '');

  if (!q) {
    // クエリが空（':' のみ入力）の場合: 最近使った絵文字を最優先で表示し、残りを標準/カスタムから補完
    const recentSet = new Set(recents);
    const seen = new Set<string>();
    const results: AutocompleteEmoji[] = [];

    // 1. 最近使った絵文字から探す
    for (const r of recents) {
      const match = allEmojis.find(
        (e) => e.shortcode.toLowerCase() === r.toLowerCase()
      );
      if (match && !seen.has(match.shortcode)) {
        seen.add(match.shortcode);
        results.push(match);
        if (results.length >= limit) return results;
      }
    }

    // 2. 残りをカスタム絵文字および標準絵文字から埋める
    for (const e of allEmojis) {
      if (!seen.has(e.shortcode)) {
        seen.add(e.shortcode);
        results.push(e);
        if (results.length >= limit) return results;
      }
    }

    return results;
  }

  // クエリがある場合のスコアリング
  type ScoredEmoji = { emoji: AutocompleteEmoji; score: number };
  const scored: ScoredEmoji[] = [];
  const seenShortcodes = new Set<string>();

  for (const item of allEmojis) {
    if (seenShortcodes.has(item.shortcode)) continue;
    seenShortcodes.add(item.shortcode);

    const sc = item.shortcode.toLowerCase();
    let score = 0;

    // 1. 短コードの完全一致
    if (sc === q) {
      score += 1000;
    }
    // 2. エイリアスの完全一致
    else if (item.aliases.some((a) => a.toLowerCase() === q)) {
      score += 800;
    }
    // 3. 短コードの前方一致
    else if (sc.startsWith(q)) {
      score += 500 - (sc.length - q.length) * 2;
    }
    // 4. エイリアスの前方一致
    else if (item.aliases.some((a) => a.toLowerCase().startsWith(q))) {
      const best = item.aliases
        .filter((a) => a.toLowerCase().startsWith(q))
        .reduce((min, a) => Math.min(min, a.length), 999);
      score += 400 - (best - q.length) * 2;
    }
    // 5. 短コードの部分一致
    else if (sc.includes(q)) {
      score += 200 - sc.indexOf(q) * 2;
    }
    // 6. エイリアスの部分一致
    else if (item.aliases.some((a) => a.toLowerCase().includes(q))) {
      score += 150;
    }
    // 7. カテゴリ名の一致
    else if (item.category && item.category.toLowerCase().includes(q)) {
      score += 100;
    }

    if (score > 0) {
      // 最近使った絵文字の加点 (最大 +200)
      const recentIdx = recents.findIndex(
        (r) => r.toLowerCase() === sc
      );
      if (recentIdx >= 0) {
        score += Math.max(0, 200 - recentIdx * 10);
      }

      // カスタム絵文字を標準絵文字よりわずかに優先
      if (item.url) {
        score += 20;
      }

      scored.push({ emoji: item, score });
    }
  }

  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, limit).map((s) => s.emoji);
}
