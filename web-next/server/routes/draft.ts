// SPDX-License-Identifier: AGPL-3.0-or-later
// 書きかけ(ふつうのノート)── 頁を離れても、ほかの端末へ行っても、続きから書ける。
//
//   POST /compose/draft          いまの書きかけを gateway へ置く(本文も注意書きも空なら、畳む)。書く欄が、手を止めたあとに送る。
//   POST /compose/draft/discard  「消す」を押したとき。
//
// gateway(/api/i/notes/drafts)は、一アカウントに一つ。連合しない。返信・引用・記事・共有からの書き出しには、置かない(web と同じ)。
// gateway の口は、ここ一か所: 開くとき(GET /compose)は readDraft、送れたとき(POST /compose)は pruneDraft がここを通る。
// 置きそこねても、書くことは止めない ── 読めなければ「無かった」ことに、畳みそこねは、そのまま流す(web の「失敗は黙って飲む」と同じ)。

import { gw, gwJson, GatewayError } from '../gateway.ts';
import { empty, route, type Ctx } from '../http.ts';
import { needMe, quiet } from './shared.ts';

// 書く欄に戻す形(compose の values と同じ名前)。
export type DraftValues = { status: string; spoiler: string; sensitive: boolean; visibility: string };

type Stored = { text: string; spoiler: string; sensitive: boolean; visibility: string };

const PATH = '/api/i/notes/drafts';
const blank = (s: string): boolean => s.trim() === '';

// 開くとき。中身があれば、書く欄に戻す形で。読めない・空なら null(頁は、いつもどおり開く)。
export async function readDraft(ctx: Ctx): Promise<DraftValues | null> {
  try {
    const d = await gwJson<Stored | null>(ctx, 'GET', PATH);
    if (!d || (blank(d.text ?? '') && blank(d.spoiler ?? ''))) return null;
    return { status: d.text ?? '', spoiler: d.spoiler ?? '', sensitive: !!d.sensitive, visibility: d.visibility || 'public' };
  } catch (e) {
    if (e instanceof GatewayError || e instanceof TypeError) return null;
    throw e;
  }
}

// 送れたとき・消したとき・空になったとき。
export async function pruneDraft(ctx: Ctx): Promise<void> {
  try {
    await gw(ctx, 'DELETE', PATH);
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
  }
}

route(
  'POST',
  '/compose/draft',
  quiet(async (ctx) => {
    await needMe(ctx);
    const f = await ctx.form();
    const str = (k: string) => String(f.get(k) ?? '');
    const text = str('status');
    const spoiler = str('spoiler_text');
    if (blank(text) && blank(spoiler)) {
      await pruneDraft(ctx);
      return empty(204);
    }
    // 公開範囲が四つのどれかであることは、gateway が検める(だめなら 422 ── そのまま返す)。
    await gwJson(ctx, 'PUT', PATH, {
      json: { text, spoiler, useSpoiler: !blank(spoiler), sensitive: f.get('sensitive') === '1', visibility: str('visibility') || 'public' }
    });
    return empty(204);
  })
);

route(
  'POST',
  '/compose/draft/discard',
  quiet(async (ctx) => {
    await needMe(ctx);
    await pruneDraft(ctx);
    return empty(204);
  })
);
