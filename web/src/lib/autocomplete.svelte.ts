// 統合オートコンプリート（絵文字 `:` および メンション `@`）の状態管理。
//
// 入力中のカーソル位置からトリガー文字（`:` / `@`）を判別し、
// 絵文字の即時検索またはメンションのデバウンス検索を実行します。

import { searchAll, getCustomEmojis, type Account, type Emoji } from './api';
import { fragmentAt as mentionFragmentAt, applyPick as applyMentionPick, type Fragment as MentionFragment } from './mention';
import { emojiFragmentAt, applyEmojiPick, type EmojiFragment } from './emoji-autocomplete';
import { searchEmojis, setCustomEmojisCache, recordRecentEmoji, type AutocompleteEmoji } from './emoji-search';

export type AutocompleteItem =
  | { type: 'emoji'; emoji: AutocompleteEmoji }
  | { type: 'mention'; account: Account };

export function createAutocomplete(options?: { mentionDelayMs?: number }) {
  const mentionDelay = options?.mentionDelayMs ?? 200;

  let items = $state<AutocompleteItem[]>([]);
  let active = $state(0);
  let trigger = $state<':' | '@' | null>(null);
  let mentionFrag = $state<MentionFragment | null>(null);
  let emojiFrag = $state<EmojiFragment | null>(null);

  let mentionTimer: ReturnType<typeof setTimeout> | null = null;
  let mentionSeq = 0;
  let emojisLoaded = false;

  async function ensureEmojisLoaded() {
    if (emojisLoaded) return;
    try {
      const list = await getCustomEmojis();
      setCustomEmojisCache(list || []);
      emojisLoaded = true;
    } catch {
      // ネットワーク失敗時は標準絵文字のみで動作継続
    }
  }

  // 初期化時にバックグラウンドでカスタム絵文字をキャッシュ
  if (typeof window !== 'undefined') {
    void ensureEmojisLoaded();
  }

  function close() {
    if (mentionTimer !== null) clearTimeout(mentionTimer);
    mentionTimer = null;
    mentionSeq += 1;
    items = [];
    active = 0;
    trigger = null;
    mentionFrag = null;
    emojiFrag = null;
  }

  function look(text: string, caret: number) {
    // 1. 絵文字トリガー判定 (`:query`)
    const ef = emojiFragmentAt(text, caret);
    if (ef) {
      if (mentionTimer !== null) clearTimeout(mentionTimer);
      trigger = ':';
      emojiFrag = ef;
      mentionFrag = null;
      const emojiResults = searchEmojis(ef.query, 8);
      items = emojiResults.map((e) => ({ type: 'emoji', emoji: e }));
      active = 0;
      return;
    }

    // 2. メンショントリガー判定 (`@query`)
    const mf = mentionFragmentAt(text, caret);
    if (mf && mf.query.length > 0) {
      trigger = '@';
      mentionFrag = mf;
      emojiFrag = null;
      if (mentionTimer !== null) clearTimeout(mentionTimer);
      const mine = ++mentionSeq;
      mentionTimer = setTimeout(async () => {
        try {
          const r = await searchAll(mf.query, { type: 'accounts', limit: 6 });
          if (mine !== mentionSeq) return;
          items = r.accounts.map((a) => ({ type: 'mention', account: a }));
          active = 0;
        } catch {
          if (mine === mentionSeq) items = [];
        }
      }, mentionDelay);
      return;
    }

    // 該当するトリガーがない場合は閉じる
    close();
  }

  function move(delta: number) {
    if (items.length === 0) return;
    active = (active + delta + items.length) % items.length;
  }

  function pick(text: string, index = active): { text: string; caret: number } | null {
    const item = items[index];
    if (!item) return null;

    if (item.type === 'emoji' && emojiFrag) {
      const replacement = item.emoji.unicode || `:${item.emoji.shortcode}:`;
      recordRecentEmoji(item.emoji.shortcode);
      const res = applyEmojiPick(text, emojiFrag, replacement);
      close();
      return res;
    }

    if (item.type === 'mention' && mentionFrag) {
      const res = applyMentionPick(text, mentionFrag, item.account.acct);
      close();
      return res;
    }

    return null;
  }

  return {
    get items() {
      return items;
    },
    get active() {
      return active;
    },
    get trigger() {
      return trigger;
    },
    get open() {
      return items.length > 0;
    },
    get mentionFragment() {
      return mentionFrag;
    },
    get emojiFragment() {
      return emojiFrag;
    },
    look,
    close,
    move,
    pick,
    ensureEmojisLoaded
  };
}
