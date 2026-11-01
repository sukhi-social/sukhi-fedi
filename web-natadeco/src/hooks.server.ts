import type { Handle } from '@sveltejs/kit/hooks';
import { AsyncLocalStorage } from 'node:async_hooks';
import { siteOf } from '#lib/site.js';
import { setServerCookieSource } from '#lib/api.js';

// 請求の Cookie を、その請求を描いているあいだだけ api.ts に見せる。
// load は await をまたぐので、module の変数では別の人の請求と混ざる ──
// AsyncLocalStorage なら、await の向こうでも自分の請求のまま。
const requestCookie = new AsyncLocalStorage<string>();
setServerCookieSource(() => requestCookie.getStore() ?? null);

// サーバで描くとき、どちらの言語で描くか。ブラウザなら localStorage の
// 選択か端末の言語で決める(i18n.svelte.ts の detectLang)が、サーバに
// 見えるのは Accept-Language だけ ── 上から順に見て、先に来たほう。
// 選んで切り替えている人は、hydrate のあとブラウザ側が自分の選択に
// 直す(一瞬だけ、サーバの推測が見える)。
function pickLang(header: string | null): 'ja' | 'ko' {
  for (const part of (header ?? '').split(',')) {
    const base = part.trim().split(';')[0].toLowerCase().split('-')[0];
    if (base === 'ko') return 'ko';
    if (base === 'ja') return 'ja';
  }
  return 'ja';
}

// gateway への申告書。gateway が前に立つとき、内側から読みに来る
// (ドット始まりの道は、外からは取れない)。頁の見分けはここが知っている
// ── 知らない道は 404 を返すので、gateway には「全部」と申告する。
// 札は session_token だけ(SSR が API に渡して、入った姿を描く)。
const WEB_MANIFEST = JSON.stringify({
  name: 'web-board',
  claims: [{ path: '/**' }],
  cookies: ['session_token']
});

export const handle: Handle = async ({ event, resolve }) => {
  if (event.url.pathname === '/.sukhi/web.json') {
    return new Response(WEB_MANIFEST, {
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
    });
  }
  event.locals.lang = pickLang(event.request.headers.get('accept-language'));
  // どの玄関か。Elixir が `x-forwarded-host` に載せて渡してくる
  // (HOST_HEADER で SvelteKit の url.hostname にもなる)。
  event.locals.site = siteOf(event.url.hostname);

  return requestCookie.run(event.request.headers.get('cookie') ?? '', () =>
    resolve(event, {
      // app.html の `<html lang="ja">` を、描く言語に合わせる。ブラウザ側の
      // inline script はそのあと localStorage の選択で上書きする。
      // 部屋の印(`data-site`)も一緒に。ブラウザ側の道つなぎ(hooks.ts)は
      // これを見る ── 手元の mock のように、実際の hostname が玄関と
      // 違うことがあるので、サーバが決めたほうに揃える。
      transformPageChunk: ({ html }) =>
        html.replace(
          '<html lang="ja">',
          `<html lang="${event.locals.lang}"${event.locals.site === 'travel' ? ' data-site="travel"' : ''}>`
        )
    })
  );
};
