// SPDX-License-Identifier: AGPL-3.0-or-later
// 頁の枠。<head>・ナビ・<main>・スクリプトの順番を、ここ一か所で決める。
//
// Cloudflare のメール保護は、頁の中のアドレスを「[email protected]」に書き換える。<!--email_off--> の間は、そのまま通す。
// Unpoly は、いつも <main up-main> を差し替える。だから、入ったか出たかで変わるもの(ナビ)は
// <main> の外に置き、ログイン・ログアウト・ことば替えは、ふつうのフォーム(フルリロード)にする。
// 頁そのものは、View Transitions の下絵(@view-transition)が、静かにつなぐ。

import { config } from '../config.ts';
import { html, type SafeHtml } from '../html.ts';
import type { Ctx } from '../http.ts';
import type { Account } from '../types.ts';
import { avatar, icon, entranceBar, legalFooter, type IconName } from './parts.ts';
import type { TranslationKey } from '../i18n.ts';

type Page = {
  title: string;
  body: SafeHtml;
  me?: Account | null;
  // 入る前の画面(帯と、法的ページへの入り口を出す)。
  entrance?: boolean;
  // 本文の下に、法的ページへの入り口を出す。
  legal?: boolean;
  description?: string;
};

type Flow = { href: string; key: TranslationKey; icon: IconName };

const FLOW: Record<string, Flow> = {
  compose: { href: '/compose', key: 'nav.compose', icon: 'compose' },
  home: { href: '/', key: 'nav.home', icon: 'home' },
  notifications: { href: '/notifications', key: 'nav.notifications', icon: 'bell' },
  search: { href: '/search', key: 'nav.search', icon: 'search' }
};

function flowLink(ctx: Ctx, f: Flow): SafeHtml {
  const current = ctx.url.pathname === f.href || (f.href === '/' && ctx.url.pathname === '/timeline');
  // 数字も、点も、バッジも、付けない。通知は「あるかどうか」を急かさない。
  return html`<a class="nav-link nav-flow" href="${f.href}" up-preload aria-current="${current ? 'page' : null}">
    ${icon(f.icon)}
    <span class="nav-text"><span class="nav-label">${ctx.t(f.key)}</span></span>
  </a>`;
}

function appNav(ctx: Ctx, me: Account): SafeHtml {
  const name = me.display_name || me.username;
  const top = [FLOW.compose, FLOW.home, FLOW.notifications, FLOW.search];
  const bottom = [FLOW.home, FLOW.search, FLOW.compose, FLOW.notifications];
  const profileHref = `/@${me.acct}`;
  return html`<header class="app-nav">
    <div class="wrap app-nav-row">
      <a class="app-nav-name" href="/" up-preload>
        <img class="app-nav-mark" src="${config.siteLogo}" alt="" width="64" height="64" />${config.siteName}
      </a>
      <nav class="nav-top" aria-label="${ctx.t('nav.label')}" up-nav>
        ${top.map((f) => flowLink(ctx, f))}
        <div class="nav-menu" x-data="{ open: false }" @click.outside="open = false" @keydown.escape="open = false" @closemenus.document="open = false">
          <button type="button" class="nav-link nav-menu-trigger nav-avatar-trigger" aria-haspopup="menu" :aria-expanded="open" aria-label="${ctx.t('nav.account')}" @click="open = !open">
            ${avatar(me.avatar, name, 'nav-avatar')}
          </button>
          <div class="nav-menu-panel" role="menu" x-show="open" x-cloak x-transition.opacity.duration.150ms>
            <a class="nav-menu-item" role="menuitem" href="${profileHref}" aria-current="${ctx.url.pathname === profileHref ? 'page' : null}">${icon('user')}<span>${ctx.t('nav.profile')}</span></a>
            <a class="nav-menu-item" role="menuitem" href="/settings" aria-current="${ctx.url.pathname === '/settings' ? 'page' : null}">${icon('settings')}<span>${ctx.t('nav.settings')}</span></a>
            <div class="nav-menu-sep" role="separator"></div>
            <form method="post" action="/logout">
              <button type="submit" class="nav-menu-item" role="menuitem">${icon('logout')}<span>${ctx.t('nav.logout')}</span></button>
            </form>
          </div>
        </div>
      </nav>
    </div>
  </header>
  <nav class="nav-bottom" aria-label="${ctx.t('nav.bottomLabel')}" up-nav>
    ${bottom.map((f) => flowLink(ctx, f))}
  </nav>`;
}

export function layout(ctx: Ctx, p: Page): SafeHtml {
  const flash = ctx.takeFlash();
  const title = p.title ? `${p.title} · ${config.siteName}` : config.siteName;
  return html`<!doctype html>
<html lang="${ctx.locale}">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, interactive-widget=resizes-content" />
  <meta name="description" content="${p.description ?? 'しずかな Fediverse のお家。'}" />
  <title>${title}</title>
  <link rel="icon"${/\.svg(\?|$)/i.test(config.siteLogo) ? ' type="image/svg+xml"' : ''} href="${config.siteLogo}" />
  <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
  <link rel="manifest" href="/manifest.webmanifest" />
  <meta name="theme-color" content="#fffaf3" media="(prefers-color-scheme: light)" />
  <meta name="theme-color" content="#1f1915" media="(prefers-color-scheme: dark)" />
  <link rel="stylesheet" href="/assets/vendor/unpoly/unpoly.min.css" />
  <link rel="stylesheet" href="/assets/css/app.css" />
  <link rel="stylesheet" href="/assets/css/components.css" />
  <link rel="stylesheet" href="/assets/css/extra.css" />
  <script src="/assets/vendor/unpoly/unpoly.min.js"></script>
  <script src="/assets/js/app.js"></script>
  <script defer src="/assets/vendor/alpine/cdn.min.js"></script>
</head>
<body>
  ${p.me ? appNav(ctx, p.me) : ''}
  <main class="wrap stack" up-main>
    ${p.entrance ? entranceBar(ctx) : ''}
    <div id="flash-container" up-hungry>
      ${flash ? html`<p class="${flash.kind === 'error' ? 'error' : 'notice'}" role="status">${flash.text}</p>` : ''}
    </div>
    <!--email_off-->
    ${p.body}
    <!--/email_off-->
    ${p.legal ? legalFooter(ctx) : ''}
  </main>
</body>
</html>`;
}
