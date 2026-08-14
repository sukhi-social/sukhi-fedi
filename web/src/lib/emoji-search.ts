// 絵文字検索・インデックスと最近使用した絵文字の管理。
//
// カスタム絵文字（API経由）と標準Unicode絵文字を統合し、
// 短コード・エイリアス（別名）・カテゴリ名から高速に候補を検索・ランキングします。

import type { Emoji } from './api';

export interface AutocompleteEmoji {
  shortcode: string;
  url?: string;
  staticUrl?: string;
  unicode?: string;
  category?: string;
  aliases: string[];
}

export const STANDARD_EMOJIS: AutocompleteEmoji[] = [
  { shortcode: '+1', unicode: '👍', aliases: ['thumbsup', 'いいね', 'グッド', 'good'], category: 'People' },
  { shortcode: 'heart', unicode: '❤️', aliases: ['love', 'ハート', 'すき', '好き'], category: 'Symbols' },
  { shortcode: 'laughing', unicode: '😆', aliases: ['lol', '笑', 'わらい', '草'], category: 'People' },
  { shortcode: 'tada', unicode: '🎉', aliases: ['party', 'おめでとう', '祝', 'クラッカー'], category: 'Activities' },
  { shortcode: 'open_mouth', unicode: '😮', aliases: ['surprised', 'びっくり', 'わあ'], category: 'People' },
  { shortcode: 'cry', unicode: '😢', aliases: ['tear', '泣き', 'かなしい', '涙'], category: 'People' },
  { shortcode: 'thinking', unicode: '🤔', aliases: ['hmm', '考える', 'うーん', '思案'], category: 'People' },
  { shortcode: 'pray', unicode: '🙏', aliases: ['thanks', 'お願いします', '合掌', '感謝', 'たすかる'], category: 'People' },
  { shortcode: 'fire', unicode: '🔥', aliases: ['flame', '炎', 'アツい', '火'], category: 'Nature' },
  { shortcode: 'sparkles', unicode: '✨', aliases: ['shine', 'きらきら', 'キラキラ', 'ピカピカ'], category: 'Nature' },
  { shortcode: 'cherry_blossom', unicode: '🌸', aliases: ['sakura', 'さくら', '桜', '花'], category: 'Nature' },
  { shortcode: 'coffee', unicode: '☕', aliases: ['cafe', 'コーヒー', 'カフェ', '珈琲'], category: 'Food' },
  { shortcode: 'tea', unicode: '🍵', aliases: ['greentea', 'お茶', '抹茶', '日本茶'], category: 'Food' },
  { shortcode: 'seedling', unicode: '🌱', aliases: ['sprout', '若葉', '芽', '草'], category: 'Nature' },
  { shortcode: 'cat', unicode: '🐈', aliases: ['neko', '猫', 'ねこ'], category: 'Animals' },
  { shortcode: 'cat_face', unicode: '🐱', aliases: ['neko', 'ねこ', '猫', 'にゃー'], category: 'Animals' },
  { shortcode: 'dog', unicode: '🐶', aliases: ['inu', '犬', 'いぬ', 'わんこ'], category: 'Animals' },
  { shortcode: 'feet', unicode: '🐾', aliases: ['paw_prints', '肉球', '足跡'], category: 'Animals' },
  { shortcode: 'bulb', unicode: '💡', aliases: ['idea', 'ひらめき', '電球', 'アイデア'], category: 'Objects' },
  { shortcode: 'eyes', unicode: '👀', aliases: ['look', '目', 'みる', 'みてる'], category: 'People' },
  { shortcode: 'clap', unicode: '👏', aliases: ['applause', '拍手', 'パチパチ'], category: 'People' },
  { shortcode: 'pleading_face', unicode: '🥺', aliases: ['plead', 'ぴえん', 'うるうる'], category: 'People' },
  { shortcode: 'smiley_cat', unicode: '😺', aliases: ['happy_cat', 'にこにこねこ'], category: 'Animals' },
  { shortcode: 'sleeping', unicode: '😴', aliases: ['sleep', 'おやすみ', 'ねる', 'zzz', '睡眠'], category: 'People' },
  { shortcode: 'heart_hands', unicode: '🫶', aliases: ['love_hands', 'ハートの手'], category: 'People' },
  { shortcode: 'dango', unicode: '🍡', aliases: ['団子', 'だんご', 'スイーツ'], category: 'Food' },
  { shortcode: 'smile', unicode: '😊', aliases: ['happy', '笑顔', 'にこ', 'にっこり'], category: 'People' },
  { shortcode: 'sob', unicode: '😭', aliases: ['crying', '号泣', 'うわーん', '大泣き'], category: 'People' },
  { shortcode: 'rofl', unicode: '🤣', aliases: ['kusa', '草', '大爆笑', 'ウケる'], category: 'People' },
  { shortcode: 'rocket', unicode: '🚀', aliases: ['launch', 'ロケット'], category: 'Travel' },
  { shortcode: '100', unicode: '💯', aliases: ['score', '百点', '満点', '完璧'], category: 'Symbols' },
  { shortcode: 'star', unicode: '⭐', aliases: ['hoshi', '星', 'スター'], category: 'Nature' },
  { shortcode: 'zap', unicode: '⚡', aliases: ['lightning', '雷', 'いなずま', '電撃'], category: 'Nature' },
  { shortcode: 'sushi', unicode: '🍣', aliases: ['すし', '寿司', 'スシ'], category: 'Food' },
  { shortcode: 'ramen', unicode: '🍜', aliases: ['noodle', 'ラーメン', 'らーめん', '拉麺'], category: 'Food' },
  { shortcode: 'onigiri', unicode: '🍙', aliases: ['rice_ball', 'おにぎり', 'おむすび'], category: 'Food' },
  { shortcode: 'beer', unicode: '🍺', aliases: ['kanpai', 'ビール', '乾杯', 'お酒'], category: 'Food' },
  { shortcode: 'cake', unicode: '🍰', aliases: ['ショートケーキ', 'ケーキ', 'おやつ'], category: 'Food' },
  { shortcode: 'muscle', unicode: '💪', aliases: ['flex', '筋肉', 'がんばる', 'マッチョ'], category: 'People' },
  { shortcode: 'notes', unicode: '🎶', aliases: ['music', '音符', 'おんぷ', '歌'], category: 'Symbols' },
  { shortcode: 'crescent_moon', unicode: '🌙', aliases: ['moon', '月', 'つき', '三日月'], category: 'Nature' },
  { shortcode: 'sunny', unicode: '☀️', aliases: ['sun', '太陽', 'たいよう', '晴れ'], category: 'Nature' },
  { shortcode: 'cloud', unicode: '☁️', aliases: ['くもり', '雲'], category: 'Nature' },
  { shortcode: 'umbrella', unicode: '☔', aliases: ['rain', '雨', 'あめ', '傘'], category: 'Nature' },
  { shortcode: 'snowflake', unicode: '❄️', aliases: ['snow', '雪', 'ゆき', '冬'], category: 'Nature' },
  { shortcode: 'strawberry', unicode: '🍓', aliases: ['いちご', '苺'], category: 'Food' },
  { shortcode: 'apple', unicode: '🍎', aliases: ['ringo', 'りんご', '林檎'], category: 'Food' },
  { shortcode: 'penguin', unicode: '🐧', aliases: ['ペンギン', 'ぺんぎん'], category: 'Animals' },
  { shortcode: 'bear', unicode: '🐻', aliases: ['kuma', 'くま', '熊'], category: 'Animals' },
  { shortcode: 'rabbit', unicode: '🐰', aliases: ['usagi', 'うさぎ', '兎'], category: 'Animals' }
];

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
        unicode: 'unicode' in e ? e.unicode : undefined,
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
  const allEmojis = [...customEmojiCache, ...STANDARD_EMOJIS];
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
        (e) => e.shortcode.toLowerCase() === r.toLowerCase() || (e.unicode && e.unicode === r)
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
        (r) => r.toLowerCase() === sc || (item.unicode && r === item.unicode)
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
