import { AsyncLocalStorage } from 'node:async_hooks';
import type { Handle } from '@sveltejs/kit';
import { siteOf } from '$lib/site';
import { setServerCookieSource } from '$lib/api';

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

export const handle: Handle = async ({ event, resolve }) => {
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
