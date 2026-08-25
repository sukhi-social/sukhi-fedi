// ナタデコの PWA 用 service worker。オフライン用のキャッシュは持たない
// (掲示板は読むたびに新しい中身を取りに行くべきなので、素通しでいい)。
// ここにあるのは (1) インストール可能にすること (2) push を受けて
// 通知を出すこと (3) 通知をタップしたら該当のスレッドを開くこと、の3つ。

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', () => {
  // 素通し。キャッシュ戦略を持たない ── 掲示板は常に最新を見せたい。
});

// サーバ側(SukhiFedi.Addons.WebPush.payload_for/1)は、本文もアバターも
// 乗せない ── 「誰かが話しかけた」だけを伝える。ロック画面プレビューに
// 中身が漏れないように、という向こう側の設計を尊重して、ここでも本文を
// 作り出さない(from の acct だけ)。
self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    // 中身が読めなくても、知らせること自体はする。
  }

  const title = data.from ? `@${data.from} さんから` : 'ナタデコ';
  const options = {
    body: 'あなたの投稿に返信がありました',
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    tag: data.notification_id ? `notif-${data.notification_id}` : undefined,
    data: { noteId: data.note_id }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const noteId = event.notification.data && event.notification.data.noteId;
  const url = noteId ? `/posts/${noteId}` : '/';

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ('focus' in client) {
          client.navigate(url);
          return client.focus();
        }
      }
      return self.clients.openWindow(url);
    })
  );
});
