// SPDX-License-Identifier: AGPL-3.0-or-later
// BOT の鍵。パスワードも画面ログインも無く、鍵(token)だけで動くアカウントの、鍵を足す。名前と期限つき。
//   GET  /settings/bot   名前と期限の欄
//   POST /settings/bot   gateway の POST /api/v1/sukhi/tokens へ。返事に載った鍵を、その一回だけ見せる
// 鍵は gateway が返事に一度しか載せない。だから、ここも「預からない」: セッション(ディスクに書く)にも、flash にも置かず、
// POST の返事にだけ出す。キャッシュさせないのは、郵便局の入口(http.ts)が、HTMLの返事ぜんぶに付けているのでここでは足さない。
// 古い鍵は閉じない(足すだけ)。

import { gwJson, GatewayError } from '../gateway.ts';
import { html, type SafeHtml } from '../html.ts';
import { ok, route, type Ctx, type Reply } from '../http.ts';
import type { TranslationKey } from '../i18n.ts';
import { layout } from '../views/layout.ts';
import { needMe } from './shared.ts';

type PersonalToken = { name: string; token: string; expires_in_days: number };

// 期限(日)。gateway に送る数は、この中だけ。
const DAYS: [number, TranslationKey][] = [
  [7, 'bot.days7'],
  [30, 'bot.days30'],
  [90, 'bot.days90'],
  [365, 'bot.days365']
];
const DEFAULT_DAYS = 90;
const NAME_MAX = 40;

async function botPage(ctx: Ctx, o: { issued?: PersonalToken; error?: string; name?: string; days?: number; status?: number } = {}): Promise<Reply> {
  const t = ctx.t;
  const me = await needMe(ctx);
  const days = o.days ?? DEFAULT_DAYS;
  const body: SafeHtml = html`<header class="timeline page-head"><h1>${t('bot.title')}</h1></header>
    <div class="timeline stack">
      <p class="prose-small">${t('bot.help')}</p>
      ${o.error ? html`<p class="error" role="alert">${o.error}</p>` : ''}
      ${o.issued
        ? html`<p class="notice" role="status">${t('bot.tokenOnce')}</p>
            <p class="prose-small">${t('bot.issuedFor', { name: o.issued.name, days: o.issued.expires_in_days })}</p>
            <p><code class="token-once">${o.issued.token}</code></p>`
        : ''}
      <section class="stack">
        <h2 class="text-base">${t('bot.mineTitle')}</h2>
        <p class="prose-small">${t('bot.mineHelp')}</p>
        <form class="settings-form" method="post" action="/settings/bot">
          <label class="stack-tight">
            <span>${t('bot.tokenName')}</span>
            <input type="text" name="name" value="${o.issued ? '' : (o.name ?? '')}" maxlength="${NAME_MAX}" autocomplete="off" required />
          </label>
          <label class="stack-tight">
            <span>${t('bot.expires')}</span>
            <select name="days">
              ${DAYS.map(([d, key]) => html`<option value="${d}" ${d === days ? 'selected' : ''}>${t(key)}</option>`)}
            </select>
          </label>
          <div><button type="submit" class="btn">${t('bot.issue')}</button></div>
        </form>
      </section>
      <p class="prose-small"><a class="chip" href="/settings">${t('security.backToSettings')}</a></p>
    </div>`;
  return ok(layout(ctx, { title: t('bot.title'), me, body }), o.status ?? 200);
}

route('GET', '/settings/bot', (ctx) => botPage(ctx));

route('POST', '/settings/bot', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const name = String(f.get('name') ?? '').trim().slice(0, NAME_MAX);
  const asked = Number(f.get('days'));
  const days = DAYS.some(([d]) => d === asked) ? asked : DEFAULT_DAYS;
  if (!name) return botPage(ctx, { error: ctx.t('bot.failed'), days, status: 422 });
  try {
    const issued = await gwJson<PersonalToken>(ctx, 'POST', '/api/v1/sukhi/tokens', { json: { name, expires_in_days: days } });
    return botPage(ctx, { issued, days });
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    return botPage(ctx, { error: ctx.t('bot.failed'), name, days, status: e instanceof GatewayError && e.status === 429 ? 429 : 422 });
  }
});
