// SPDX-License-Identifier: AGPL-3.0-or-later
// データの書き出し・読み込み: フォロー・ブロック・ミュートを、Mastodon と同じ一列の CSV(`Account address`)で。
// 別のサーバへ持っていく・持ってくるための頁。元の web には無かったもので、gateway に口を足した
// (api の MastodonAccountPorter / gateway の AccountPorter)。読み方・上限・解決・書き込みは gateway の仕事で、
// ここは、ファイルを渡して、返ってきた件数を言うだけ。読み込みは「足す」だけ ── いまあるものは消さない。

import { GatewayError, gw, gwJson } from '../gateway.ts';
import { html } from '../html.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import type { TranslationKey } from '../i18n.ts';
import { layout } from '../views/layout.ts';
import { failText, needMe } from './shared.ts';

const KINDS = ['following', 'blocks', 'mutes'] as const;
type Kind = (typeof KINDS)[number];
const isKind = (v: string): v is Kind => (KINDS as readonly string[]).includes(v);

const MAX_FILE = 256 * 1024; // gateway の上限と揃える

const LABEL: Record<Kind, TranslationKey> = {
  following: 'data.following',
  blocks: 'data.blocks',
  mutes: 'data.mutes'
};

type ImportResult = { imported: number; skipped: number; unresolved: string[] };

async function dataPage(ctx: Ctx, o: { error?: { kind: Kind; text: string }; status?: number } = {}): Promise<Reply> {
  const t = ctx.t;
  const me = await needMe(ctx);
  const section = (kind: Kind) => html`<section class="stack-tight">
    <h2 class="text-base">${t(LABEL[kind])}</h2>
    <div>
      <a class="chip" href="/settings/data/export/${kind}" download="${kind}.csv">${t('data.export')}</a>
    </div>
    <form class="stack-tight" method="post" action="/settings/data/import/${kind}" enctype="multipart/form-data">
      <label class="stack-tight">
        <span>${t('data.file')}</span>
        <input type="file" name="file" accept=".csv,text/csv,text/plain" required />
      </label>
      <div><button type="submit" class="btn px-6 py-2">${t('data.import')}</button></div>
      ${o.error?.kind === kind ? html`<p class="error" role="alert">${o.error.text}</p>` : ''}
    </form>
  </section>`;

  const body = html`<header class="timeline page-head"><h1>${t('data.title')}</h1></header>
    <div class="timeline stack">
      <div class="settings-form">
        <p class="muted">${t('data.intro')}</p>
        ${KINDS.map(section)}
        <p class="muted text-sm">${t('data.note')}</p>
        <p class="prose-small"><a class="chip" href="/settings">${t('security.backToSettings')}</a></p>
      </div>
    </div>`;
  return ok(layout(ctx, { title: t('data.title'), me, body }), o.status ?? 200);
}

route('GET', '/settings/data', (ctx) => dataPage(ctx));

route('GET', '/settings/data/export/:kind', async (ctx) => {
  await needMe(ctx);
  const kind = ctx.params.kind;
  if (!isKind(kind)) return redirect('/settings/data');
  const res = await gw(ctx, 'GET', `/api/v1/accounts/export/${kind}`);
  return {
    status: 200,
    headers: {
      'content-type': 'text/csv; charset=utf-8',
      'content-disposition': `attachment; filename="${kind}.csv"`,
      'cache-control': 'no-store'
    },
    body: await res.text()
  };
});

route('POST', '/settings/data/import/:kind', async (ctx) => {
  const t = ctx.t;
  await needMe(ctx);
  const kind = ctx.params.kind;
  if (!isKind(kind)) return redirect('/settings/data');
  const fail = (text: string, status = 422) => dataPage(ctx, { error: { kind, text }, status });

  // 本文を読む前に、大きさで断る(ctx.form() は丸ごとメモリに読む)。ふつうの CSV は 256KB まで。
  if (Number(ctx.req.headers['content-length'] ?? 0) > MAX_FILE + 16 * 1024) return fail(t('data.err.tooLarge'), 413);

  const f = await ctx.form();
  const file = f.get('file');
  if (!(file instanceof File) || file.size === 0) return fail(t('data.err.empty'));
  if (file.size > MAX_FILE) return fail(t('data.err.tooLarge'), 413);

  try {
    const r = await gwJson<ImportResult>(ctx, 'POST', `/api/v1/accounts/import/${kind}`, { json: { data: await file.text() } });
    ctx.flash('notice', r.skipped > 0 ? t('data.done.skipped', { n: r.imported, m: r.skipped }) : t('data.done', { n: r.imported }));
    return redirect('/settings/data');
  } catch (e) {
    if (e instanceof GatewayError) {
      if (e.message === 'too_large') return fail(t('data.err.tooLarge'), 413);
      if (e.message === 'too_many_rows') return fail(t('data.err.tooMany'));
      return fail(failText(ctx, e), e.status === 429 ? 429 : 422);
    }
    if (e instanceof TypeError) return fail(failText(ctx, e), 502);
    throw e;
  }
});
