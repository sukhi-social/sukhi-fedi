// SPDX-License-Identifier: AGPL-3.0-or-later
// 設定の頁: プロフィールの編集(表示名・自己紹介・ひとこと欄・アイコン・ヘッダ)、ひろがりかた
// (鍵・BOT・見つけやすさ)、通知のペース。ぜんぶ gateway の PATCH update_credentials 一本で保存する。
// ログインと安全(routes/security.ts)・アカウントの引っ越し(routes/migration.ts)は、別の頁で、ここから行く。
//
// 書き込みの道は一本(POST /settings)。値を作るのも、確かめるのも、gateway(Accounts.update_credentials)の
// 仕事で、ここは、フォームの形を gateway の形に写すだけ。ことばの切り替えだけは cookie なので /lang へ。

import { config } from '../config.ts';
import { GatewayError, gwJson } from '../gateway.ts';
import { html, type SafeHtml } from '../html.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import { LOCALES, LOCALE_NAMES, type TranslationKey } from '../i18n.ts';
import { saveSession } from '../session.ts';
import { delayWords } from '../time.ts';
import type { Account } from '../types.ts';
import { layout } from '../views/layout.ts';
import { avatar } from '../views/parts.ts';
import { nameOf } from '../views/account.ts';
import { failText, needMe } from './shared.ts';

const MAX_FIELDS = 4;
const MAX_UPLOAD = 8 * 1024 * 1024; // gateway の avatar/header の上限と揃える
const HOLD_STEPS = [0, 15, 30, 60, 180, 720, 1440];

type Values = {
  display_name: string;
  note: string;
  location: string;
  birthday: string;
  fields: { name: string; value: string }[];
  locked: boolean;
  bot: boolean;
  discoverable: boolean;
  indexable: boolean;
  hold: number;
  grouping: boolean;
};

// いまの値(verify_credentials の source から)。自己紹介は、書いたままの原文で開き直す。
function valuesOf(me: Account): Values {
  return {
    display_name: me.display_name ?? '',
    note: me.source?.note ?? '',
    location: me.location ?? '',
    birthday: me.birthday ?? '',
    fields: (me.source?.fields ?? []).map((f) => ({ name: f.name, value: f.value })),
    locked: !!me.locked,
    bot: !!me.bot,
    discoverable: !!me.discoverable,
    indexable: !!me.indexable,
    hold: me.source?.notification_hold_minutes ?? 0,
    grouping: !!me.source?.notification_grouping
  };
}

function holdLabel(ctx: Ctx, min: number): string {
  return HOLD_STEPS.includes(min)
    ? ctx.t(`settings.hold${min}` as TranslationKey)
    : ctx.t('settings.holdOther', { n: min });
}

async function settingsPage(ctx: Ctx, me: Account, v: Values, error?: string, status = 200): Promise<Reply> {
  const t = ctx.t;
  const holds = HOLD_STEPS.includes(v.hold) ? HOLD_STEPS : [...HOLD_STEPS, v.hold].sort((a, b) => a - b);
  const rows = [...v.fields, ...Array.from({ length: MAX_FIELDS }, () => ({ name: '', value: '' }))].slice(0, MAX_FIELDS);
  const check = (name: string, label: string, on: boolean) =>
    html`<label class="stack-tight"><input type="checkbox" name="${name}" value="1" ${on ? 'checked' : ''} /><span>${label}</span></label>`;
  const flash = ctx.takeFlash();
  const showHeader = me.header && !me.header.startsWith('data:'); // 無いバナーは 1×1 の透明 PNG で来る

  const body: SafeHtml = html`<header class="timeline page-head"><h1>${t('settings.title')}</h1></header>
    <div class="timeline stack">
      ${flash ? html`<p class="${flash.kind === 'error' ? 'error' : 'notice'}" role="status">${flash.text}</p>` : ''}
      <nav class="settings-nav" aria-label="${t('settings.title')}">
        <ul>
          <li><a class="chip" href="/settings/security">${t('settings.security')}</a></li>
          <li><a class="chip" href="/settings/migration">${t('settings.migration')}</a></li>
          <li><a class="chip" href="/settings/data">${t('settings.data')}</a></li>
        </ul>
      </nav>
      <form class="settings-form" method="post" action="/settings" enctype="multipart/form-data">
        <p class="muted">@${me.acct}</p>

        <section class="stack">
          <h2 class="text-base">${t('settings.profile')}</h2>

          <label class="stack-tight">
            <span>${t('settings.displayName')}</span>
            <input type="text" name="display_name" value="${v.display_name}" maxlength="100" />
          </label>

          <label class="stack-tight">
            <span>${t('settings.bio')}</span>
            <textarea name="note" rows="4" maxlength="1024">${v.note}</textarea>
            <small class="muted">${t('settings.bioHint')}</small>
          </label>

          <label class="stack-tight">
            <span>${t('settings.location')}</span>
            <input type="text" name="location" value="${v.location}" maxlength="128" />
          </label>

          <label class="stack-tight">
            <span>${t('settings.birthday')}</span>
            <input type="date" name="birthday" value="${v.birthday}" />
          </label>

          <div class="stack-tight">
            <span>${t('settings.fields')}</span>
            <p class="muted text-sm">${t('settings.fieldsHint')}</p>
            ${rows.map(
              (f) => html`<div class="field-row">
                <input type="text" name="field_name" value="${f.name}" maxlength="255" placeholder="${t('settings.fieldName')}" aria-label="${t('settings.fieldName')}" />
                <input type="text" name="field_value" value="${f.value}" maxlength="512" placeholder="${t('settings.fieldValue')}" aria-label="${t('settings.fieldValue')}" />
              </div>`
            )}
          </div>

          <label class="stack-tight">
            <span>${t('settings.avatarNow')}</span>
            ${avatar(me.avatar, nameOf(me), 'avatar avatar-lg')}
            <input type="file" name="avatar" accept="image/*" />
          </label>

          <label class="stack-tight">
            <span>${t('settings.headerNow')}</span>
            ${showHeader ? html`<img class="profile-header" src="${me.header}" alt="" />` : ''}
            <input type="file" name="header" accept="image/*" />
            <small class="muted">${t('settings.avatarKeep')}</small>
          </label>
        </section>

        <section class="stack">
          <h2 class="text-base">${t('settings.visibility')}</h2>
          <div class="settings-checks">
            ${check('locked', t('settings.locked'), v.locked)}
            ${check('bot', t('settings.bot'), v.bot)}
            ${check('discoverable', t('settings.discoverable'), v.discoverable)}
            ${check('indexable', t('settings.indexable'), v.indexable)}
            <p class="muted">${t('settings.searchConsentHint')}</p>
          </div>
        </section>

        <section class="stack">
          <h2 class="text-base">${t('settings.pace')}</h2>
          <p class="muted text-sm">${t('settings.paceHint')}</p>
          <label class="stack-tight">
            <span>${t('settings.paceHold')}</span>
            <select name="hold">
              ${holds.map((m) => html`<option value="${m}" ${m === v.hold ? 'selected' : ''}>${holdLabel(ctx, m)}</option>`)}
            </select>
          </label>
          <div class="settings-checks">${check('grouping', t('settings.paceGrouping'), v.grouping)}</div>
          ${config.notifyHoldMin > 0
            ? html`<p class="muted text-sm">${t('settings.paceFloor', { when: delayWords(config.notifyHoldMin, ctx.locale) })}</p>`
            : ''}
        </section>

        ${error ? html`<p class="error" role="alert">${error}</p>` : ''}
        <div class="hstack" style="--gap: var(--space-3)">
          <button type="submit" class="btn primary px-6 py-2">${t('settings.save')}</button>
        </div>
      </form>

      <form class="settings-form" method="post" action="/lang">
        <input type="hidden" name="next" value="/settings" />
        <section class="stack-tight">
          <h2 class="text-base">${t('settings.language')}</h2>
          <p class="muted text-sm">${t('settings.languageHint')}</p>
          <div class="hstack" style="--gap: var(--space-2)">
            ${LOCALES.map(
              (l) => html`<button type="submit" name="l" value="${l}" class="chip" lang="${l}" aria-pressed="${ctx.locale === l ? 'true' : 'false'}">${LOCALE_NAMES[l]}</button>`
            )}
          </div>
        </section>
      </form>
    </div>`;
  return ok(layout(ctx, { title: t('settings.title'), me, body }), status);
}

route('GET', '/settings', async (ctx) => {
  const me = await needMe(ctx);
  return settingsPage(ctx, me, valuesOf(me));
});

route('POST', '/settings', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const f = await ctx.form();
  const str = (k: string) => String(f.get(k) ?? '');
  const on = (k: string) => f.get(k) === '1';

  const names = f.getAll('field_name').map(String);
  const values = f.getAll('field_value').map(String);
  const fields = names
    .map((name, i) => ({ name: name.trim(), value: (values[i] ?? '').trim() }))
    .filter((x) => x.name || x.value)
    .slice(0, MAX_FIELDS);
  const hold = Math.min(1440, Math.max(0, Math.round(Number(str('hold')) || 0)));

  const v: Values = {
    display_name: str('display_name'),
    note: str('note'),
    location: str('location'),
    birthday: str('birthday'),
    fields,
    locked: on('locked'),
    bot: on('bot'),
    discoverable: on('discoverable'),
    indexable: on('indexable'),
    hold,
    grouping: on('grouping')
  };

  // 画像は、選ばれたときだけ送る(空のままなら、いまのまま)。
  const picked = (k: string) => {
    const x = f.get(k);
    return x instanceof File && x.size > 0 ? x : null;
  };
  const avatarFile = picked('avatar');
  const headerFile = picked('header');
  if ((avatarFile && avatarFile.size > MAX_UPLOAD) || (headerFile && headerFile.size > MAX_UPLOAD)) {
    return settingsPage(ctx, me, v, t('settings.fileTooLarge'), 422);
  }

  const fd = new FormData();
  fd.set('display_name', v.display_name);
  fd.set('note', v.note);
  fd.set('location', v.location);
  fd.set('birthday', v.birthday);
  fd.set('fields', JSON.stringify(fields));
  for (const k of ['locked', 'bot', 'discoverable', 'indexable'] as const) fd.set(k, String(v[k]));
  fd.set('notification_hold_minutes', String(v.hold));
  fd.set('notification_grouping', String(v.grouping));
  if (avatarFile) fd.set('avatar', avatarFile);
  if (headerFile) fd.set('header', headerFile);

  try {
    const updated = await gwJson<Account>(ctx, 'PATCH', '/api/v1/accounts/update_credentials', { form: fd });
    // 返ってきた自分を手元にひかえ直す(ナビのアイコンも、これを読む)。
    const s = ctx.sess();
    s.me = updated;
    saveSession(s);
    ctx.flash('notice', t('settings.saved'));
    return redirect('/settings');
  } catch (e) {
    if (e instanceof GatewayError || e instanceof TypeError) return settingsPage(ctx, me, v, failText(ctx, e), e instanceof GatewayError && e.status === 422 ? 422 : 502);
    throw e;
  }
});
