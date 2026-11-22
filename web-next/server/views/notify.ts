// SPDX-License-Identifier: AGPL-3.0-or-later
// ベルの横に出る、通知の「まだ見ていない」しるし。
//   direct  ── 数字そのまま。バッジにしない(赤も丸もなく、ただの数字)。
//   ambient ── 数字を出さず、未見の量で育つかたち(、→ 。→ w → Λ → A → 木)。
// 数え方・層の分け方は server/notify.ts、ここは描くだけ。

import { html, type SafeHtml } from '../html.ts';
import type { Ctx } from '../http.ts';
import type { Tier } from '../notify.ts';

// 文字そのものは使わない(「w」は日本語の画面では笑ってしまうし、「A」はアルファベットに読まれる)。
// 点→満ちた円→起伏→山→構造→木、という成り立ちだけを借りて、ちいさなシルエットで描く。
// 段の境い目は読めなくていい ── 離れていた間に変わったと感じられることが目的で、木が上限。
// 色は currentColor(chip の文字色にそのまま従う)。動きはつけない ── 変わる瞬間は誰も見ないから。
function glyph(count: number): SafeHtml {
  const stage = count <= 1 ? 1 : count <= 3 ? 2 : count <= 6 ? 3 : count <= 11 ? 4 : count <= 19 ? 5 : 6;
  switch (stage) {
    case 1: // 、 ── 点がひとつ
      return html`<svg class="notif-glyph" viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="7.5" r="1.7" fill="currentColor" /></svg>`;
    case 2: // 。 ── 満ちて、ひとまとまりに
      return html`<svg class="notif-glyph" viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6.5" r="3" fill="none" stroke="currentColor" stroke-width="1.5" /></svg>`;
    case 3: // w ── 起伏。静かだったものが、すこし動き出す
      return html`<svg class="notif-glyph" viewBox="0 0 12 12" aria-hidden="true"><path d="M1.5 8.5 Q3.1 5.5 4.75 8.5 Q6.4 5.5 8 8.5 Q9.2 6.3 10.5 8.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /></svg>`;
    case 4: // Λ ── 上に伸びる
      return html`<svg class="notif-glyph" viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 9.5 L6 2.8 L9.5 9.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>`;
    case 5: // A ── 山に横棒が入って、立つものになる
      return html`<svg class="notif-glyph" viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 9.5 L6 2.8 L9.5 9.5 M4.2 6.9 L7.8 6.9" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>`;
    default: // 木 ── ここが上限。これ以上は、木のまま
      return html`<svg class="notif-glyph" viewBox="0 0 12 12" aria-hidden="true"><line x1="6" y1="10.5" x2="6" y2="6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /><circle cx="6" cy="4.4" r="3" fill="currentColor" /></svg>`;
  }
}

export type Where = 'top' | 'bottom';

// しるしの置き場。ナビには、上の帯と下の帯の二か所に同じ通知のリンクがあるので、場所ごとに id を持つ。
// 層ごとに別の置き場にしておく ── 流れで届いたとき(direct)は、ambient を動かさずに、数字だけを差し替えられる。
// 数が無い(count を渡さない・0)ときは、空のまま ── 何も出ない。
// 読み上げには、かたちでなく言葉で正直に。
export function notifSlots(ctx: Ctx, where: Where, count?: Record<Tier, number>): SafeHtml {
  const d = count?.direct ?? 0;
  const a = count?.ambient ?? 0;
  return html`<span class="notif-slot" id="notif-direct-${where}">${d > 0
    ? html`<span class="notif-count" aria-hidden="true">${d}</span><span class="visually-hidden">${ctx.t('nav.notifDirect', { n: d })}</span>`
    : ''}</span><span class="notif-slot" id="notif-ambient-${where}">${a > 0
    ? html`${glyph(a)}<span class="visually-hidden">${ctx.t('nav.notifAmbient')}</span>`
    : ''}</span>`;
}
