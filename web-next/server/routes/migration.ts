// SPDX-License-Identifier: AGPL-3.0-or-later
// アカウントの引っ越し(Mastodon の Move と alsoKnownAs)。静かに。元の web の /settings/migration の置き換え。
//
// 別名(これも自分)を編集でき、引っ越し先がこちらを別名に入れていれば(双方向の同意)、引っ越せる。
// 引っ越し済みなら、行き先だけを素直に出す。数も煽りも出さない。妥当性と上限を見るのは gateway。

import { GatewayError, gwJson } from '../gateway.ts';
import { html } from '../html.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import type { TranslationKey } from '../i18n.ts';
import { layout } from '../views/layout.ts';
import { failText, needMe } from './shared.ts';

const MAX_ALIASES = 5;

type Migration = { aliases?: string[]; moved_to?: string | null };

// gateway のことば → こちらで言えることば。知らないものは generic ── 言える分だけ静かに言う。
const MOVE_ERRORS: Record<string, TranslationKey> = {
  target_must_alias_back: 'migration.err.target_must_alias_back',
  invalid_target: 'migration.err.invalid_target',
  already_moved: 'migration.err.already_moved'
};

type Opts = {
  // 入力の途中のまま戻すとき(失敗・「足す」)。
  aliases?: string[];
  target?: string;
  error?: { where: 'aliases' | 'move'; text: string };
  status?: number;
};

async function migrationPage(ctx: Ctx, o: Opts = {}): Promise<Reply> {
  const t = ctx.t;
  const me = await needMe(ctx);
  const m = await gwJson<Migration>(ctx, 'GET', '/api/v1/accounts/migration');
  const movedTo = m.moved_to ?? null;
  const aliases = o.aliases ?? m.aliases ?? [];
  // 書く欄は、足りていれば一つ余分に(空の欄は、保存のとき捨てる)。
  const rows = aliases.length < MAX_ALIASES ? [...aliases, ''] : aliases;
  const err = (where: 'aliases' | 'move') =>
    o.error?.where === where ? html`<p class="error" role="alert">${o.error.text}</p>` : '';

  const body = html`<header class="timeline page-head"><h1>${t('migration.title')}</h1></header>
    <div class="timeline stack">
      <section class="settings-form">
        <p class="muted">${t('migration.intro')}</p>

        ${movedTo
          ? html`<p class="prose-small">${t('migration.moved')} <a href="${movedTo}" target="_blank" rel="noopener noreferrer">${movedTo}</a></p>`
          : ''}

        <form class="stack-tight" method="post" action="/settings/migration/aliases">
          <h2 class="text-base">${t('migration.aliasesTitle')}</h2>
          <p class="muted text-sm">${t('migration.aliasesHelp')}</p>
          ${aliases.every((a) => a === '') ? html`<p class="prose-small">${t('migration.aliasesNone')}</p>` : ''}
          ${rows.map(
            (a, i) => html`<div class="alias-row">
              <input type="url" name="alias" value="${a}" maxlength="512" placeholder="${t('migration.aliasPlaceholder')}" aria-label="${t('migration.aliasesTitle')}" />
              ${a ? html`<button type="submit" class="chip" name="remove" value="${i}" formnovalidate>${t('migration.aliasRemove')}</button>` : ''}
            </div>`
          )}
          ${rows.length < MAX_ALIASES
            ? html`<div><button type="submit" class="chip" name="more" value="1" formnovalidate>${t('migration.aliasAdd')}</button></div>`
            : ''}
          <div class="hstack" style="--gap: var(--space-3)">
            <button type="submit" class="btn primary px-6 py-2">${t('settings.save')}</button>
          </div>
          ${err('aliases')}
        </form>

        ${movedTo
          ? ''
          : html`<form class="stack-tight" method="post" action="/settings/migration/move" up-confirm="${t('migration.moveConfirm')}">
              <h2 class="text-base">${t('migration.moveTitle')}</h2>
              <p class="muted text-sm">${t('migration.moveHelp')}</p>
              <input type="url" name="target" value="${o.target ?? ''}" maxlength="512" placeholder="${t('migration.movePlaceholder')}" aria-label="${t('migration.moveTitle')}" required />
              <div><button type="submit" class="btn px-6 py-2">${t('migration.moveButton')}</button></div>
              ${err('move')}
            </form>`}

        <p class="prose-small"><a class="chip" href="/settings">${t('security.backToSettings')}</a></p>
      </section>
    </div>`;
  return ok(layout(ctx, { title: t('migration.title'), me, body }), o.status ?? 200);
}

route('GET', '/settings/migration', (ctx) => migrationPage(ctx));
// 元の web には /migration の口は無いが、Mastodon の習いで /migration と打つ人のために、静かに案内する。
route('GET', '/migration', () => redirect('/settings/migration'));

route('POST', '/settings/migration/aliases', async (ctx) => {
  const t = ctx.t;
  await needMe(ctx);
  const f = await ctx.form();
  let list = f.getAll('alias').map((a) => String(a).trim());

  // 「消す」は、その行を外して保存する。「足す」は、保存せずに、欄を一つ増やして返す。
  const remove = f.get('remove');
  if (remove !== null) list = list.filter((_, i) => i !== Number(remove));
  if (f.get('more') === '1') {
    return migrationPage(ctx, { aliases: [...list, ''].slice(0, MAX_ALIASES) });
  }
  const cleaned = list.filter((a) => a !== '');

  try {
    await gwJson<{ aliases: string[] }>(ctx, 'POST', '/api/v1/accounts/migration/aliases', { json: { aliases: cleaned } });
    ctx.flash('notice', t('migration.aliasesSaved'));
    return redirect('/settings/migration');
  } catch (e) {
    if (e instanceof GatewayError || e instanceof TypeError) {
      const text = e instanceof GatewayError && e.status >= 500 ? failText(ctx, e) : t('migration.err.generic');
      return migrationPage(ctx, { aliases: cleaned, error: { where: 'aliases', text }, status: 422 });
    }
    throw e;
  }
});

route('POST', '/settings/migration/move', async (ctx) => {
  const t = ctx.t;
  await needMe(ctx);
  const f = await ctx.form();
  const target = String(f.get('target') ?? '').trim();
  if (!target) return redirect('/settings/migration');

  try {
    await gwJson<{ moved_to: string | null }>(ctx, 'POST', '/api/v1/accounts/migration/move', { json: { target } });
    return redirect('/settings/migration');
  } catch (e) {
    if (e instanceof GatewayError || e instanceof TypeError) {
      const key = e instanceof GatewayError ? MOVE_ERRORS[e.message] : undefined;
      const text = key ? t(key) : e instanceof GatewayError && e.status >= 500 ? failText(ctx, e) : t('migration.err.generic');
      return migrationPage(ctx, { target, error: { where: 'move', text }, status: 422 });
    }
    throw e;
  }
});
