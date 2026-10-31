// SPDX-License-Identifier: AGPL-3.0-or-later
// 歓迎の専用頁(/welcome)。
// チュートリアル形式で、アプリの紹介と Chrome 向け PWA インストール推薦を案内する。

import { html } from '../html.ts';
import { ok, route, type Ctx, type Reply } from '../http.ts';
import { layout } from '../views/layout.ts';

function welcomePage(ctx: Ctx): Reply {
  const t = ctx.t;
  const me = ctx.session?.token ? ctx.session?.me : null;

  const body = html`<div class="measure stack welcome-container" data-welcome-page>
    <section class="hero">
      <h1>${t('pwa.welcomeTitle')}</h1>
    </section>

    <div class="welcome-card stack" data-pwa-step="welcome">
      <p class="prose-small">${t('pwa.welcomeDesc')}</p>
      <div class="pwa-install-actions">
        <button type="button" class="btn primary px-6 py-2" data-pwa-next>${t('pwa.welcomeNext')}</button>
      </div>
    </div>

    <div class="welcome-card stack" data-pwa-step="prompt" hidden>
      <h2 class="text-base">${t('pwa.installTitle')}</h2>
      <p class="prose-small">${t('pwa.installBanner')}</p>
      <div class="pwa-install-actions">
        <button type="button" class="btn primary px-6 py-2" data-pwa-install>${t('pwa.installBtn')}</button>
        <button type="button" class="btn secondary px-6 py-2" data-pwa-dismiss>${t('pwa.dismissBtn')}</button>
      </div>
    </div>

    <div class="welcome-card stack" data-pwa-step="installed" hidden>
      <h2 class="text-base">${t('pwa.installedTitle')}</h2>
      <p class="prose-small">${t('pwa.installedMsg')}</p>
      <div class="pwa-install-actions">
        <a href="/" class="btn primary px-6 py-2" data-pwa-start>${t('pwa.closeBtn')}</a>
      </div>
    </div>

    <div class="welcome-card stack" data-pwa-step="skipped" hidden>
      <h2 class="text-base">${t('pwa.skippedTitle')}</h2>
      <p class="prose-small">${t('pwa.skippedMsg')}</p>
      <div class="pwa-install-actions">
        <a href="/" class="btn primary px-6 py-2" data-pwa-start>${t('pwa.closeBtn')}</a>
      </div>
    </div>
  </div>`;

  return ok(layout(ctx, { title: t('pwa.welcomeTitle'), entrance: !me, legal: true, body }));
}

route('GET', '/welcome', (ctx) => welcomePage(ctx));
