// 書いている途中の `:…` (絵文字短コードや日本語エイリアス) を、文の中から見つけるところ。
//
// ここは書き手の文を書き換える場所なので、境目だけを純粋な関数にして切り出してある
// (runes を使わず DOM にも依存しないので `node --test` でそのまま走る)。

/** カーソル直前の、まだ書きかけの `:短コード`。無ければ null。 */
export type EmojiFragment = {
  start: number;
  end: number;
  query: string;
};

// 行頭か、空白・約物(括弧や引用符)の直後にあるコロンから始まる語を拾う。
// 文中の URL (https://...) や時刻 (12:30)、閉じられた絵文字 (:cat:) の後ろは拾わない。
const EMOJI_FRAGMENT = /(^|[\s　([「『（【〔［{｛<《〈＜"'"'‘'“”]):([^\s:　)\]」』）】〕］}｝>》〉＞"'"'‘'“”]*)$/u;

/**
 * いま打っている絵文字短コードの fragment を返す。
 * 空白で区切られたあとや、文中のコロン (URL / 時刻等) は無視する。
 */
export function emojiFragmentAt(text: string, caret: number): EmojiFragment | null {
  if (caret < 0 || caret > text.length) return null;
  const m = EMOJI_FRAGMENT.exec(text.slice(0, caret));
  if (!m) return null;
  const query = m[2];
  return {
    start: caret - query.length - 1,
    end: caret,
    query
  };
}

/**
 * 候補を選んだあとの、本文とカーソル位置を計算する。
 * 選んだ絵文字の後ろに空白を一つ添え、続けて文字を打てるようにする。
 */
export function applyEmojiPick(
  text: string,
  f: EmojiFragment,
  emoji: string
): { text: string; caret: number } {
  let inserted: string;
  if (emoji.startsWith(':') && emoji.endsWith(':')) {
    inserted = `${emoji} `;
  } else if (/^[\w+\-@.]+$/u.test(emoji)) {
    inserted = `:${emoji}: `;
  } else {
    // Unicode 絵文字または装飾文字列など
    inserted = `${emoji} `;
  }

  return {
    text: text.slice(0, f.start) + inserted + text.slice(f.end),
    caret: f.start + inserted.length
  };
}
