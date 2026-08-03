// 一覧に出す「ひとこと」を作る。
//
// 会話の一覧は、中身を読む場所ではなく **どの会話か思い出す場所**。
// 投稿カードをそのまま並べると、名前も時刻も操作ボタンも二重に出て、
// 肝心の「なんの話だったか」が埋もれる。ここは一行にほどく。

/** タグを落として、一行のふつうの文にする。 */
export function plainText(html: string | null | undefined): string {
  return String(html ?? '')
    .replace(/<br\s*\/?>/g, ' ')
    .replace(/<\/p>/g, ' ')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .trim()
    .replace(/\s+/gu, ' ');
}

/**
 * 本文あたまの @言及 を落とす。
 *
 * DM の宛先は本文の `@` 言及で決まるので、どの一通も相手の名前で始まる。
 * 一覧では、それが全部の行の先頭に並ぶ ── 自分の名前を何度も読むことに
 * なるので、ここでは外す。
 *
 * **`plainText()` を通したあとに呼ぶこと。** 言及は h-card の span に
 * 包まれて来るため、HTML のままだと行頭が `<p><span…` で `^@` に当たらない。
 */
export function stripLeadingMentions(text: string): string {
  return text.replace(/^(?:\s*@[\w.\-]+(?:@[\w.\-]+)?)+/u, '').trim();
}

/**
 * 末尾が「言及だけの段落」なら、その段落ごと落とす。
 *
 * sukhi の composer は DM の宛先を末尾に回す(書き出しに相手の名前が
 * 居座らないように)。受け取る側では、それは配達の宛名であって本文では
 * ないので、出さない。**言及だけの段落**に限る ── 文が混じっていれば、
 * それは書き手が書いたもの。
 */
function stripTrailingMentionParagraph(s: string): string {
  if (!/<\/p>\s*$/i.test(s)) return s;

  // 内部の形(h-card の入れ子)を当てにしない ── そこで一度すべった。
  // 最後の段落を切り出して、タグと言及を全部抜いて、何も残らなければ宛名。
  const start = s.toLowerCase().lastIndexOf('<p');
  if (start <= 0) return s; // 段落が一つだけなら、先頭側の規則に任せる
  const open = s.indexOf('>', start);
  if (open < 0) return s;

  const inner = s.slice(open + 1, s.toLowerCase().lastIndexOf('</p>'));
  if (!inner.includes('@')) return s;

  const bare = inner
    .replace(/<[^>]+>/g, '')
    .replace(/@[\w.\-]+(?:@[\w.\-]+)?/gu, '')
    .replace(/[\s　]/gu, '');
  return bare === '' ? s.slice(0, start) : s;
}

/**
 * HTML のまま、あたまの言及だけを外す。
 *
 * DM の宛先は本文の `@` 言及で決まる(サーバの契約)ので、どの一通も相手の
 * 名前で始まる。二人しかいない会話でそれを毎行読まされるのは、ただの重複
 * ── 誰が書いたかは、名前と左の線がもう言っている。
 *
 * 落とすのは **h-card に包まれた、先頭の言及だけ**。文中の言及も、素の
 * `@` で始まる文も触らない。本文は表示のためにほどくが、送られたものは
 * そのまま残る(サーバ側は言及つきのまま)。
 */
export function stripLeadingMentionHtml(html: string | null | undefined): string {
  const s = stripTrailingMentionParagraph(String(html ?? ''));

  const open = /^\s*<p[^>]*>/i.exec(s);
  if (!open) return s;

  const head = open[0];
  let i = head.length;

  // h-card は入れ子(<span class="h-card"><a>@<span>acct</span></a></span>)なので、
  // 正規表現で `</span>` まで、では内側で閉じてしまう。span の開閉を数える。
  const closeSpanFrom = (from: number): number => {
    let depth = 0;
    const tag = /<(\/?)span\b[^>]*>/giu;
    tag.lastIndex = from;
    let m: RegExpExecArray | null;
    while ((m = tag.exec(s))) {
      depth += m[1] ? -1 : 1;
      if (depth === 0) return tag.lastIndex;
    }
    return -1;
  };

  for (;;) {
    const rest = s.slice(i);
    const ws = /^\s*/u.exec(rest)![0].length;
    const at = i + ws;

    if (/^<span class="h-card"/i.test(s.slice(at))) {
      const end = closeSpanFrom(at);
      if (end < 0) break;
      i = end;
      continue;
    }

    // h-card に包まれていない素の言及も、あたまなら落とす。
    const bare = /^@[\w.\-]+(?:@[\w.\-]+)?/u.exec(s.slice(at));
    if (bare) {
      i = at + bare[0].length;
      continue;
    }

    i = at;
    break;
  }

  return i === head.length ? s : head + s.slice(i);
}

/** 一覧に出す一行。HTML をほどいて、あたまの言及を外して、長すぎたら畳む。 */
export function previewOf(html: string | null | undefined, limit = 140): string {
  const text = stripLeadingMentions(plainText(html));
  return text.length > limit ? text.slice(0, limit) + '…' : text;
}
