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

/** 一覧に出す一行。HTML をほどいて、あたまの言及を外して、長すぎたら畳む。 */
export function previewOf(html: string | null | undefined, limit = 140): string {
  const text = stripLeadingMentions(plainText(html));
  return text.length > limit ? text.slice(0, limit) + '…' : text;
}
