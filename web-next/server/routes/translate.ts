// SPDX-License-Identifier: AGPL-3.0-or-later
// 投稿の翻訳: 「訳を見る」を押したとき(POST /statuses/:id/translate)と、翻訳の設定の頁。
// docs/TRANSLATION.md。
//
// 守り(DM は訳さない・限定公開は DeepL に送らない・長さ・回数)は、ぜんぶ gateway の
// SukhiFedi.Translate の一か所。ここは、押されたことを伝えて、返ってきた訳(か、できなかった理由)を
// 原文の下に置くだけ。黙って別の訳し役に替えたり、自動で訳したりはしない。
//
// このファイルは、write.ts の `/statuses/:id/:verb` より前に読まれる(上から先に当たった道が受ける)。

import { GatewayError, gwJson } from '../gateway.ts';
import { html, type SafeHtml } from '../html.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import { saveSession } from '../session.ts';
import { baseLang, prefsOf, translationEnabled, warmTranslation } from '../translate.ts';
import type { Account, Status } from '../types.ts';
import { layout } from '../views/layout.ts';
import { endonym, type Slot, type Translation } from '../views/translate.ts';
import { statusCard } from '../views/status.ts';
import { failText, needMe, replyAcctsFor } from './shared.ts';

// ── 押したとき ──────────────────────────────────────────────────
route('POST', '/statuses/:id/translate', async (ctx) => {
  const me = await needMe(ctx);
  const id = encodeURIComponent(ctx.params.id);
  const f = await ctx.form();
  const dom = /^[\w-]{1,80}$/.test(String(f.get('dom') ?? '')) ? String(f.get('dom')) : `st-${ctx.params.id}`;
  const lang = prefsOf(me, ctx.locale).target;

  let slot: Slot;
  try {
    const result = await gwJson<Translation>(ctx, 'POST', `/api/v1/statuses/${id}/translate`, { json: { lang } });
    slot = { result };
  } catch (e) {
    // 理由は gateway の error ことばで来る。知らないことば・届かなかったときは「訳せませんでした」。
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    slot = { problem: e instanceof GatewayError ? e.message : 'engine_unavailable' };
  }

  // Unpoly なら、訳の場所だけを返す。そうでなければ(JS なし)、投稿ごとの頁を返す。
  const s = await gwJson<Status>(ctx, 'GET', `/api/v1/statuses/${id}`, { auth: 'optional' });
  const replyAccts = await replyAcctsFor(ctx, [s]);
  const card = statusCard(ctx, s, { me, replyAccts, domId: dom.startsWith('st-') ? undefined : dom, full: !ctx.isUp, translation: slot });
  if (!ctx.isUp) return ok(layout(ctx, { title: ctx.t('translate.see'), me, body: html`<section class="timeline">${card}</section>` }));
  return ok(card);
});

// ── 設定 ────────────────────────────────────────────────────────
// 読める・学べることばの候補。(gateway が受けるのは 2〜3 字のコードなら何でも。画面には、よくあるものを。)
const COMMON = ['ja', 'en', 'ko', 'zh', 'es', 'fr', 'de', 'pt', 'it', 'ru', 'id', 'th'];

type Values = { reads: string[]; learns: string[]; engine: 'libre' | 'deepl' };

function valuesOf(me: Account): Values {
  const list = (a: string[] | undefined) => (a ?? []).map((x) => baseLang(x)).filter((x): x is string => !!x);
  return { reads: list(me.source?.translate_reads), learns: list(me.source?.translate_learns), engine: me.source?.translate_engine === 'deepl' ? 'deepl' : 'libre' };
}

async function translationPage(ctx: Ctx, me: Account, v: Values, error?: string, status = 200): Promise<Reply> {
  const t = ctx.t;
  const hint = me.source?.translate_deepl_key_hint ?? null;
  const flash = ctx.takeFlash();
  const choices = [...new Set([...COMMON, ...v.reads, ...v.learns])];
  const checks = (name: 'reads' | 'learns', on: string[]) =>
    choices.map(
      (c) => html`<label class="stack-tight"><input type="checkbox" name="${name}" value="${c}" ${on.includes(c) ? 'checked' : ''} /><span lang="${c}">${endonym(c)}</span></label>`
    );
  const enabled = translationEnabled();

  const body: SafeHtml = html`<header class="timeline page-head"><h1>${t('translate.settings')}</h1></header>
    <div class="timeline stack">
      ${flash ? html`<p class="${flash.kind === 'error' ? 'error' : 'notice'}" role="status">${flash.text}</p>` : ''}
      <form class="settings-form" method="post" action="/settings/translation" x-data="{ engine: '${v.engine}' }">
        <p class="muted">${t('translate.set.lead')}</p>

        <section class="stack-tight">
          <h2 class="text-base">${t('translate.set.readsTitle')}</h2>
          <p class="muted text-sm">${t('translate.set.readsHint')}</p>
          <div class="settings-checks">${checks('reads', v.reads)}</div>
        </section>

        <section class="stack-tight">
          <h2 class="text-base">${t('translate.set.learnsTitle')}</h2>
          <p class="muted text-sm">${t('translate.set.learnsHint')}</p>
          <div class="settings-checks">${checks('learns', v.learns)}</div>
        </section>

        <section class="stack">
          <h2 class="text-base">${t('translate.set.engineTitle')}</h2>
          <div class="settings-checks">
            <label class="stack-tight"><input type="radio" name="engine" value="libre" x-model="engine" ${v.engine === 'libre' ? 'checked' : ''} /><span>${t('translate.set.engineLibre')}${enabled ? '' : ` ${t('translate.set.engineLibreOff')}`}</span></label>
            <label class="stack-tight"><input type="radio" name="engine" value="deepl" x-model="engine" ${v.engine === 'deepl' ? 'checked' : ''} /><span>${t('translate.set.engineDeepl')}</span></label>
          </div>
          <p class="muted text-sm">${t('translate.set.engineHint')}</p>

          <!-- DeepL を選ぶところに、一度だけ。タイムラインでは言わない(訳の欄に、エンジン名が出ている)。 -->
          <div class="tr-note" role="note" x-show="engine === 'deepl'">
            <h3>${t('translate.set.consentTitle')}</h3>
            <p>${t('translate.set.consent1')}</p>
            <p class="muted text-sm">${t('translate.set.consent2')}</p>
          </div>
          <div class="stack-tight" x-show="engine === 'deepl'">
            <label class="stack-tight">
              <span>${t('translate.set.keyLabel')}</span>
              <input type="password" name="translate_deepl_key" placeholder="${t('translate.set.keyPlaceholder')}" autocomplete="off" spellcheck="false" />
            </label>
            <p class="muted text-sm">${t('translate.set.keyHint')}</p>
          </div>

          <!-- 入っているキーと、消すボタン。訳し役がどちらを向いていても見える(DeepL を選んでいなくても、消せる)。
               消すのは別の form(この form の中に form は置けないので、form 属性でつなぐ)── 保存は待たない。 -->
          ${hint
            ? html`<div class="hstack" style="--gap: var(--space-3)">
                <p class="text-sm">${t('translate.set.keyNow', { hint })}</p>
                <button type="submit" form="tr-key-clear" class="chip">${t('translate.set.keyClear')}</button>
              </div>`
            : ''}
        </section>

        ${error ? html`<p class="error" role="alert">${error}</p>` : ''}
        <div class="hstack" style="--gap: var(--space-3)">
          <button type="submit" class="btn primary px-6 py-2">${t('settings.save')}</button>
          <a class="chip" href="/settings">${t('translate.set.back')}</a>
        </div>
      </form>
      ${hint ? html`<form id="tr-key-clear" method="post" action="/settings/translation/key-clear" up-confirm="${t('translate.set.keyClearConfirm')}"></form>` : ''}
    </div>`;
  return ok(layout(ctx, { title: t('translate.settings'), me, body }), status);
}

route('GET', '/settings/translation', async (ctx) => {
  const me = await needMe(ctx);
  await warmTranslation(ctx);
  return translationPage(ctx, me, valuesOf(me));
});

route('POST', '/settings/translation', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const f = await ctx.form();
  const codes = (k: string) => [...new Set(f.getAll(k).map((x) => baseLang(String(x))).filter((x): x is string => !!x))];
  const v: Values = { reads: codes('reads'), learns: codes('learns'), engine: f.get('engine') === 'deepl' ? 'deepl' : 'libre' };
  const key = String(f.get('translate_deepl_key') ?? '').trim();

  const hasKey = !!me.source?.translate_deepl_key_hint;
  if (v.engine === 'deepl' && !key && !hasKey) return translationPage(ctx, me, v, t('translate.set.needKey'), 422);

  const fd = new FormData();
  fd.set('translate_reads', v.reads.join(','));
  fd.set('translate_learns', v.learns.join(','));
  fd.set('translate_engine', v.engine);
  // 書きこみ専用: 入っているときだけ送る(空のままなら、いまのキーのまま)。
  if (key) fd.set('translate_deepl_key', key);

  try {
    const updated = await gwJson<Account>(ctx, 'PATCH', '/api/v1/accounts/update_credentials', { form: fd });
    const s = ctx.sess();
    s.me = updated;
    saveSession(s);
    ctx.flash('notice', t('settings.saved'));
    return redirect('/settings/translation');
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    if (e instanceof GatewayError && e.status === 422) {
      const d = e.details ?? {};
      if (d.translate_deepl_key_input || d.translate_deepl_key) return translationPage(ctx, me, v, t('translate.set.badKey'), 422);
      if (d.translate_engine) return translationPage(ctx, me, v, t('translate.set.needKey'), 422);
    }
    return translationPage(ctx, me, v, failText(ctx, e), e instanceof GatewayError && e.status === 422 ? 422 : 502);
  }
});

// キーを消す。押す → 確認(up-confirm)→ 消す → 訳し役は、この場所のものに戻る。
// 「戻す」は gateway の一か所(キーを消すと、engine が deepl なら同じ手で nil に戻る)。ここは、消すと伝えるだけ。
// 読めることば・学ぶことばには触らない。
route('POST', '/settings/translation/key-clear', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const fd = new FormData();
  fd.set('translate_deepl_key_clear', 'true');
  try {
    const updated = await gwJson<Account>(ctx, 'PATCH', '/api/v1/accounts/update_credentials', { form: fd });
    const s = ctx.sess();
    s.me = updated;
    saveSession(s);
    ctx.flash('notice', t('translate.set.keyCleared'));
    return redirect('/settings/translation');
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    return translationPage(ctx, me, valuesOf(me), failText(ctx, e), e instanceof GatewayError && e.status === 422 ? 422 : 502);
  }
});
