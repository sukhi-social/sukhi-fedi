// SPDX-License-Identifier: AGPL-3.0-or-later
// メールのお願い ── 「いつ出すか」を決める所。出す頁の枠(views/layout.ts)と、カードを返す口(routes/nudge.ts)が、
// どちらもここを見る。メールの確認が済んでいない人にだけ、そっと、一度に一枚。
//
// 頁ごとに gateway へ聞くと、確認の済んだ人(ほとんどの人)にも、頁のたびに一往復かかる。だから:
//   - 枠は、置き場(空の <div up-defer>)だけを返す。中身は、頁が描かれたあとで /nudge から来る(頁を待たせない)
//   - 確認が済んでいる、と一度わかったら、session に印(emailOk)を立てて、その人にはもう置き場も置かない
//   - 「あとで」は cookie に ── ブラウザごとに覚える(web の localStorage と同じ。ログインし直しても静かなまま)
// cookie の形は `いつまで静かか(ms).「あとで」を押した回数`。壊れていたら、静かにしていない扱い。

import { html, type SafeHtml } from './html.ts';
import { parseCookies, type Ctx } from './http.ts';

const DAY = 24 * 60 * 60 * 1000;
// 「あとで」は 3 日。二度目のとき、30 日の静けさも選べる。
export const SNOOZE_MS = 3 * DAY;
export const LONG_SNOOZE_MS = 30 * DAY;

const COOKIE = 'sukhi_nudge';
export const NUDGE_ID = 'email-nudge';

export function quietOf(ctx: Ctx): { until: number; count: number } {
  const m = /^(\d{1,15})\.(\d{1,3})$/.exec(parseCookies(ctx.req.headers.cookie)[COOKIE] ?? '');
  return m ? { until: Number(m[1]), count: Number(m[2]) } : { until: 0, count: 0 };
}

export const snoozed = (ctx: Ctx): boolean => Date.now() < quietOf(ctx).until;

export function snooze(ctx: Ctx, ms: number, count: number): void {
  ctx.setCookie(COOKIE, `${Date.now() + ms}.${count}`, { httpOnly: true });
}

// 頁の枠に置く場所。入っている人の、ふつうの頁だけ(入口・規約・ログインと安全の頁には置かない)。
// そこに居る人には、言うまでもない。
export function nudgeSlot(ctx: Ctx, here: boolean): SafeHtml {
  if (!here || ctx.session?.emailOk || ctx.url.pathname.startsWith('/settings/security') || snoozed(ctx)) return html``;
  return html`<div id="${NUDGE_ID}" up-defer up-href="/nudge"></div>`;
}
