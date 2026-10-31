// SPDX-License-Identifier: AGPL-3.0-or-later
// web-next の service worker。Serwist で書き、scripts/build-sw.mjs が束ねて public/sw.js にする。
// 頁からは /sw?n=<サイトの名前> で呼ばれる(通知の題に使う)。
//
// 仕事は四つだけ:
//   1. 読む頁を、通れるうちに置いておく(オフラインでも、読みかえせる)
//   2. 字・画像のような、中身で URL が決まるものを置いておく(軽く、速く)
//   3. 落ちているとき、郵便局の代わりに「いまは、つながっていません」を出す
//   4. 知らせ(push)を受けて、静かに一度だけ鳴らす
//
// 触らないもの(respondWith を呼ばなければ、素通しになる):
//   /check        anubis の PoW。掴むと、解いていないブラウザに「解けた画面」を見せてしまう
//   /oauth /api   認証つきの応答。置かない
//   /settings /compose /login …  人の中身・書きかけが出る頁。置かない
//
// 更新は、すぐ入れ替わる(skipWaiting + clientsClaim)。頁は郵便局が組むので、版の食いちがいで壊れるものが無い。
// 旧 web は更新バナーがあって待たせていたが、web-next には無い ── 待たせると、直したふるまいが届かない。

import { CacheableResponsePlugin, CacheFirst, ExpirationPlugin, NetworkFirst, NetworkOnly, Serwist, StaleWhileRevalidate } from 'serwist';

const SITE = new URL(self.location.href).searchParams.get('n') || 'sukhi';

// 頁を端末に置くかどうか、の一か所。止めたいときは false に ── 置いたものは次の起動で消える
// (旧 web は「DM の本文をディスクに置くのは判断」として置かなかった。いまは home・プロフィール・投稿の
// 読む頁だけ、3 日、40 まで。出る(logout)ときは頁側で消す)。
const KEEP_PAGES = true;

const PAGES = 'sukhi-pages';
const STATIC = 'sukhi-static';
const MEDIA = 'sukhi-media';
const DAY = 24 * 60 * 60;

const here = (url) => url.origin === self.location.origin;

// 読む頁。おうちの列・タグ・プロフィール・投稿。通知・検索・設定・書く頁は含めない。
const READABLE = /^\/(?:timeline|tags\/[^/]+|@[^/]+(?:\/(?:followers|following|[^/]+))?)?\/?$/;

// 郵便局が頁を組まない道(gateway が焼く頁・認証・関所)。navigate でも触らない。
const UNTOUCHED = /^\/(?:check|oauth|api|terms|privacy|static|uploads|proxy|users|inbox|nodeinfo|\.well-known)(?:\/|$)/;

// Unpoly の要求は、同じ URL でも断片(「もっと読む」)を返すことがある。target ごとに別の鍵にして、混ぜない。
const upKey = {
  cacheKeyWillBeUsed: async ({ request }) => {
    const target = request.headers.get('x-up-target');
    if (!target) return request;
    const url = new URL(request.url);
    url.searchParams.set('__up', target);
    return url.href;
  }
};

const ok200 = new CacheableResponsePlugin({ statuses: [200] });

const runtimeCaching = [
  // 中身で URL が決まるもの(?v=、fonts、vendor、emoji)。変わらないので、置いたら、そのまま。
  {
    matcher: ({ url }) =>
      here(url) &&
      (url.pathname.startsWith('/assets/vendor/') ||
        url.pathname.startsWith('/assets/fonts/') ||
        url.pathname.startsWith('/twemoji/') ||
        (url.pathname.startsWith('/assets/') && url.searchParams.has('v'))),
    handler: new CacheFirst({
      cacheName: STATIC,
      plugins: [ok200, new ExpirationPlugin({ maxEntries: 500, maxAgeSeconds: 90 * DAY, purgeOnQuotaError: true })]
    })
  },
  // 画像(アイコン・添付・中継した画像)。置いてあるものをまず見せ、裏で新しくする。
  {
    matcher: ({ request, url }) =>
      here(url) &&
      request.destination === 'image' &&
      (url.pathname.startsWith('/proxy/') || url.pathname.startsWith('/uploads/') || url.pathname.startsWith('/brand/')),
    handler: new StaleWhileRevalidate({
      cacheName: MEDIA,
      plugins: [ok200, new ExpirationPlugin({ maxEntries: 150, maxAgeSeconds: 14 * DAY, purgeOnQuotaError: true })]
    })
  },
  // 読む頁。つながるなら新しいものを(4 秒まで待つ)、だめなら置いてあるものを。
  {
    matcher: ({ request, url }) =>
      KEEP_PAGES &&
      here(url) &&
      request.method === 'GET' &&
      (request.mode === 'navigate' || request.headers.has('x-up-version')) &&
      READABLE.test(url.pathname),
    handler: new NetworkFirst({
      cacheName: PAGES,
      networkTimeoutSeconds: 4,
      plugins: [upKey, ok200, new ExpirationPlugin({ maxEntries: 40, maxAgeSeconds: 3 * DAY, purgeOnQuotaError: true })]
    })
  },
  // ほかの navigate。置かずに、ただ通す ── 落ちていたら、下の「つながっていません」が出る。
  {
    matcher: ({ request, url }) => request.mode === 'navigate' && here(url) && !UNTOUCHED.test(url.pathname),
    handler: new NetworkOnly()
  }
];

const serwist = new Serwist({
  skipWaiting: true,
  clientsClaim: true,
  // 先読み(navigation preload)は使わない。respondWith しない道(/check ほか)でも、ブラウザは
  // 本番の要求の前に「もう一本」同じ GET を郵便局へ送り、その返事を捨てる。/check は一度きりの
  // 関所なので、捨てられる側が一度きりを使い切ると、本物の要求は /login に戻される(2026-10-31)。
  navigationPreload: false,
  runtimeCaching,
  // 開発のときのログは、いらない。
  disableDevLogs: true
});

// ── 落ちているときの画面 ──────────────────────────────────────────
// サーバにも CSS にも頼らない、これ一枚(ほんとうに落ちているときに出すものだから)。
// 責めないで、帰り道(もういちど)を置く。つながったら、自分で戻る。
const OFFLINE = {
  ja: { title: 'いまは、つながっていません', body: 'ネットワークに届きませんでした。つながったら、続きを読めます。', retry: 'もういちど' },
  ko: { title: '지금은 연결되어 있지 않아요', body: '네트워크에 닿지 않았어요. 연결되면 이어서 읽을 수 있어요.', retry: '다시 해보기' }
};

function offlinePage() {
  const lang = (self.navigator.language || 'ja').toLowerCase().startsWith('ko') ? 'ko' : 'ja';
  const t = OFFLINE[lang];
  const html = `<!doctype html>
<html lang="${lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>${t.title} · ${SITE.replace(/[<&]/g, '')}</title>
<style>
:root{--bg:#fffaf3;--text:#3d3029;--muted:#7a685b;--accent:#d9702e;--soft:#fde8d4}
@media (prefers-color-scheme:dark){:root{--bg:#1f1915;--text:#f3e9df;--muted:#b9a797;--accent:#f0a56b;--soft:#3a2b20}}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text);-webkit-tap-highlight-color:transparent}
body{display:grid;place-items:center;padding:24px;font:16px/1.8 system-ui,-apple-system,"Hiragino Sans","Noto Sans JP","Apple SD Gothic Neo",sans-serif}
main{max-width:22rem;text-align:center}
.mark{width:72px;height:72px;margin:0 auto 20px;border-radius:50%;background:var(--soft);display:grid;place-items:center;color:var(--accent)}
h1{margin:0 0 8px;font-size:1.15rem;font-weight:700}
p{margin:0 0 24px;color:var(--muted);font-size:.95rem}
button{font:inherit;font-weight:700;color:var(--bg);background:var(--accent);border:0;border-radius:999px;padding:10px 28px;min-height:44px;touch-action:manipulation;cursor:pointer}
</style></head>
<body><main role="status">
<div class="mark" aria-hidden="true"><svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 8.8a15 15 0 0 1 20 0M5 12.4a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0"/><path d="M3 3l18 18"/></svg></div>
<h1>${t.title}</h1><p>${t.body}</p>
<button type="button" onclick="location.reload()">${t.retry}</button>
</main>
<script>addEventListener('online',function(){location.reload()})</script>
</body></html>`;
  return new Response(html, { status: 503, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
}

serwist.setCatchHandler(async ({ request }) => {
  // 頁の遷移だけ、画面を出す。Unpoly の fetch や画像は、そのまま失敗にして、頁側(pwa.js)に任せる。
  if (request.destination === 'document') return offlinePage();
  return Response.error();
});

serwist.addEventListeners();

// 先読みの「入」は registration に残る(Serwist は false でも切らない)。前の版が入れたものを、ここで切る。
self.addEventListener('activate', (event) => {
  if (self.registration.navigationPreload) event.waitUntil(self.registration.navigationPreload.disable().catch(() => {}));
});

// ── ノック(push)────────────────────────────────────────────────
// ここだけが、見ていない人に届く。サーバは「これは割り込んでいい」と決めたうえで送っている
// (WebPush.deliverable?/3 ── 決める場所は一つ)ので、ここで考え直さない。運ぶだけ。
// 中身は最小限(だれから・何の種類・どの投稿)で、本文も画像も数も来ない。バッジの数字も付けない。
// docs/WEBPUSH.md §4・旧 web の service-worker.js と同じ約束。
const KNOCK = {
  ja: {
    mention: (who) => `${who} さんが話しかけています`,
    follow_request: (who) => `${who} さんから、フォローの申請が届きました`,
    someone: 'だれか'
  },
  ko: {
    mention: (who) => `${who} 님이 말을 걸고 있어요`,
    follow_request: (who) => `${who} 님에게서 팔로우 요청이 왔어요`,
    someone: '누군가'
  }
};

self.addEventListener('push', (event) => {
  let data;
  try {
    data = event.data ? event.data.json() : null;
  } catch {
    data = null;
  }
  // 読めない形で来たら、黙って何も出さない。中身の分からない通知で人を起こすのは、起こさないより悪い。
  if (!data) return;

  const text = KNOCK[(self.navigator.language || 'ja').toLowerCase().startsWith('ko') ? 'ko' : 'ja'];
  const who = data.from ? `@${data.from}` : text.someone;
  const say = text[data.notification_type] ?? text.mention;

  event.waitUntil(knock(say(who), `from-${data.notification_type ?? 'mention'}-${data.from ?? '?'}`));
});

// 人ごとに畳む(tag)。二通目は一通目を黙って差し替える(renotify は付けない)── 見ていないことの証拠は、
// その通知がまだそこにあること。見ている窓があるなら、その人はもう知っているので、鳴らさない。
async function knock(body, tag) {
  const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  if (windows.some((w) => w.visibilityState === 'visible')) return;
  await self.registration.showNotification(SITE, { body, tag, icon: '/icon-512.png', badge: '/icon-512.png', data: { url: '/notifications' } });
}

// 押したら、通知のところへ。開いている窓があればそこを使う ── タブを増やさない。
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = event.notification.data?.url ?? '/notifications';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(async (windows) => {
      for (const w of windows) {
        if (here(new URL(w.url))) {
          await w.focus();
          return w.navigate ? w.navigate(target) : undefined;
        }
      }
      return self.clients.openWindow(target);
    })
  );
});

// ブラウザが購読を替えたとき(鍵の期限など)。同じ鍵で取りなおして、郵便局に伝えなおす。
// 失敗しても、責めない ── 次に設定を開いたとき、「切れています」と出て、もういちど入れられる。
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil(
    (async () => {
      const options = event.oldSubscription?.options;
      if (!options) return;
      const sub = await self.registration.pushManager.subscribe(options);
      const json = sub.toJSON();
      const body = new URLSearchParams({ endpoint: sub.endpoint, p256dh: json.keys?.p256dh ?? '', auth: json.keys?.auth ?? '' });
      await fetch('/push/subscribe', { method: 'POST', body, credentials: 'same-origin' });
    })().catch(() => {})
  );
});
