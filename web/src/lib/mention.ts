// 書いている途中の `@…` を、文の中から見つけるところ。
//
// ここは書き手の文を書き換える場所なので、境目だけを純粋な関数にして
// 切り出してある(runes を使わないので `node --test` でそのまま走る。
// 状態を持つほうは mention.svelte.ts)。

/** カーソル直前の、まだ書きかけの `@語`。無ければ null。 */
export type Fragment = { start: number; end: number; query: string };

// 行頭か、空白・約物のあと。文中の `a@b`(メールアドレス等)は拾わない。
const FRAGMENT = /(^|[\s　([「『（【])@([\w.\-]*(?:@[\w.\-]*)?)$/u;

/**
 * いま打っている一語だけを返す。打ち終わった言及(後ろに空白がある)や、
 * 文中のメールアドレスらしきものは触らない ── 書き終えたものを後ろから
 * 書き換えられると、書き手は自分が何をしたか分からなくなる。
 */
export function fragmentAt(text: string, caret: number): Fragment | null {
  const m = FRAGMENT.exec(text.slice(0, caret));
  if (!m) return null;
  const query = m[2];
  return { start: caret - query.length - 1, end: caret, query };
}

/** 候補を選んだあとの、本文とカーソル位置。 */
export function applyPick(text: string, f: Fragment, acct: string) {
  // 選んだあとは空白を一つ。続けて書けるように、そして同じ語をもう一度
  // 補完しにいかないように(空白で fragment が切れる)。
  const inserted = `@${acct} `;
  return {
    text: text.slice(0, f.start) + inserted + text.slice(f.end),
    caret: f.start + inserted.length
  };
}
