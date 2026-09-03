import type { Handle } from '@sveltejs/kit';

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

  return resolve(event, {
    // app.html の `<html lang="ja">` を、描く言語に合わせる。ブラウザ側の
    // inline script はそのあと localStorage の選択で上書きする。
    transformPageChunk: ({ html }) =>
      html.replace('<html lang="ja">', `<html lang="${event.locals.lang}">`)
  });
};
