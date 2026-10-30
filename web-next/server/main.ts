// SPDX-License-Identifier: AGPL-3.0-or-later
// 郵便局の入り口。道(routes)を読み込んで、待ち受ける。
//
//   node server/main.ts          # Node 24 は型をそのまま読む。ビルドは要らない

import { config } from './config.ts';
import { html } from './html.ts';
import { ok, serve, setErrorPage } from './http.ts';
import { layout } from './views/layout.ts';
import './routes/auth.ts';
import './routes/read.ts';
import './routes/write.ts';
import './routes/settings.ts';
import './routes/security.ts';
import './routes/migration.ts';
import './routes/data.ts';

// 頁が見つからない・戸が閉まっている・向こうに届かない、のとき。責めずに、帰り道を置く。
setErrorPage((ctx, status) => {
  const text =
    status === 404 ? ctx.t('error.notFound')
    : status === 403 || status === 405 ? ctx.t('error.refused')
    : ctx.t('check.err.internal_error');
  return ok(
    layout(ctx, {
      title: String(status),
      entrance: true,
      body: html`<section class="hero"><h1>${text}</h1></section>
        <p class="prose-small"><a href="/">${ctx.t('common.backToTop')}</a></p>`
    }),
    status
  );
});

serve(config.port);
console.log(`sukhi-web-next: http://localhost:${config.port}  (gateway: ${config.gateway})`);
