// live の管から来た一枠を読み分ける、純粋な部分。
//
// ブラウザに触るところ(WebSocket と繋ぎ直し)は direct.svelte.ts。分けて
// あるのは、ここが黙って間違えるたちだから ── 読み違えると管は生きた
// まま何も起きず、「静か」と見分けがつかない。

/**
 * この一枠は、いま開いている会話のことか。
 *
 * サーバは Mastodon の形で送る ── `{stream, event, payload}` で、payload
 * は**それ自体が JSON の文字列**(二重に包まれている)。会話 id はその中。
 *
 * 読めない形が来たら false。分からないものを合図と見なして API を叩き
 * 続けるより、静かにしているほうがいい。
 */
export function isThisConversation(raw: unknown, conversationId: string): boolean {
  if (typeof raw !== 'string') return false;
  try {
    const frame = JSON.parse(raw) as { event?: string; payload?: unknown };
    if (frame.event !== 'conversation') return false;
    const payload =
      typeof frame.payload === 'string' ? JSON.parse(frame.payload) : frame.payload;
    return String((payload as { id?: unknown })?.id ?? '') === String(conversationId);
  } catch {
    return false;
  }
}
