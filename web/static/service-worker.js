// いちばん薄い service worker。
//
// 目的は二つだけ ── installable を満たすことと、起動を速くすること。
// オフラインで古いメッセージを見せることは **しない**。DM の本文を端末の
// ディスクに置くのは、それ自体が判断であって、「ついでに速くなる」で
// 決めることではない。開いたら shell が出て、「繋がっていません」と
// 言える。この版では、それでいい。
//
// 触らないものを、触らないままにしておくのがこのファイルの仕事の半分:
//
//   /api/*                認証つきの応答。キャッシュしない
//   /check                Anubis の PoW。ここを掴むと、解いていない
//                         ブラウザに「解けた画面」を見せてしまう
//   /_app/version.json    UpdateBanner の脈。掴むと更新が止まる
//   /uploads/*, /proxy/*  画像は browser cache に任せる
//
// 更新は既存の導線(UpdateBanner + version.pollInterval)に従わせる。
// だから `skipWaiting()` は **呼ばない** ── 勝手に入れ替わると、
// バナーと二重に「更新」が起きて、どちらが本当か分からなくなる。

const SHELL = "sukhi-shell-v1";
const IMMUTABLE = "sukhi-immutable-v1";
const KEEP = [SHELL, IMMUTABLE];

// SPA の shell。adapter-static の fallback なので、どの経路でも同じ一枚。
// だから一つの鍵で持てる。
const SHELL_URL = "/messages";

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(SHELL).then((c) => c.add(SHELL_URL)));
  // skipWaiting() は呼ばない(上記)。
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => !KEEP.includes(k)).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  let url;
  try {
    url = new URL(req.url);
  } catch {
    return;
  }
  if (url.origin !== self.location.origin) return;

  // ── 触らないもの。respondWith を呼ばなければ、素通しになる ──
  if (url.pathname.startsWith("/api/")) return;
  if (url.pathname === "/check") return;
  if (url.pathname.startsWith("/uploads/")) return;
  if (url.pathname.startsWith("/proxy/")) return;
  if (url.pathname === "/_app/version.json") return;

  // content-hash 付き。中身が変われば URL が変わるので、永久に安全。
  if (url.pathname.startsWith("/_app/immutable/")) {
    event.respondWith(cacheFirst(req));
    return;
  }

  // ページの遷移。network-first ── shell は no-cache, must-revalidate で
  // 配られている(router.ex)。その意図を殺さない。
  if (req.mode === "navigate") {
    event.respondWith(networkFirst(req));
    return;
  }
});

async function cacheFirst(req) {
  const cache = await caches.open(IMMUTABLE);
  const hit = await cache.match(req);
  if (hit) return hit;

  const res = await fetch(req);
  if (res.ok) cache.put(req, res.clone());
  return res;
}

// ── ノック ────────────────────────────────────────────────────────────
//
// ここだけが、見ていない人に届く。サーバは既に「これは割り込んでいい」と
// 決めたうえで送っている(WebPush.deliverable?/3 — 決める場所は一つ)ので、
// ここで考え直さない。運ぶだけ。
//
// 中身は最小限。だれから・何の種類・どの投稿、だけ。本文も画像も来ない
// ので、ロック画面に人の言葉が出ることはない。ノックであって、手紙を
// 顔に押しつけるのではないから。
//
// 数もつけない。バッジの数字は、このサーバがずっと避けてきた FOMO の
// かたちそのものなので。
self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    // 読めない形で来たら、黙って何も出さない。中身の分からない通知で
    // 人を起こすのは、起こさないより悪い。
    return;
  }

  const from = data.from ? `@${data.from}` : "だれか";
  const body =
    data.notification_type === "follow_request"
      ? `${from} さんから、フォローの申請が届きました`
      : `${from} さんが話しかけています`;

  // 同じ投稿へのノックは、重ねずに最新の一つへ畳む。何度も鳴るより、
  // 「まだ返していない」が一つ残っているほうが静か。
  //
  // (これは**もう出したもの**を重ねる。まだ届いていないぶんは、サーバが
  //  付ける RFC 8030 の Topic が向こう側で畳む。端末が寝ているあいだに
  //  効くのは、そちら。)
  const tag = data.note_id ? `note-${data.note_id}` : "sukhi";

  event.waitUntil(knock(body, tag, data));
});

// 見ている人を、二度呼ばない。
//
// 会話の画面は live の管で 0.2 秒で受け取る。そのうえ push まで鳴ったら、
// 一つの出来事で二回さわられることになる。**見えている窓があるなら、
// その人はもう知っている。**
//
// 判断はここでする ── サーバは誰が画面を見ているか知らないし、知るべきでも
// ない(そのために presence を持てば、それは新しい監視になる)。ブラウザは
// 自分の窓のことを知っている。知っているほうが答える。
//
// showNotification を呼ばずに済ませる回はブラウザに数えられていて、続けば
// 「バックグラウンドで更新されました」を勝手に出されることがある。ここが
// 鳴らすのは呼びかけと申請だけで数が少ないので、その線には届かない。
async function knock(body, tag, data) {
  const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  const watching = windows.some((w) => w.visibilityState === "visible");
  if (watching) return;

  await self.registration.showNotification("sukhi", {
    body,
    tag,
    icon: "/icon-512.png",
    badge: "/icon-512.png",
    data: { note_id: data.note_id ?? null, type: data.notification_type ?? null },
  });
}

// 押したら、その話のところへ。既に開いている窓があれば、そこを使う ──
// タブを増やさない。
self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  const target = "/notifications";

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
      for (const w of windows) {
        if (new URL(w.url).origin === self.location.origin) {
          w.focus();
          return w.navigate ? w.navigate(target) : undefined;
        }
      }
      return self.clients.openWindow(target);
    }),
  );
});

async function networkFirst(req) {
  try {
    const res = await fetch(req);
    // 200 のときだけ置き直す。チャレンジやエラー画面を shell として
    // 残さないため。
    if (res.ok) {
      const cache = await caches.open(SHELL);
      cache.put(SHELL_URL, res.clone());
    }
    return res;
  } catch (err) {
    const cached = await caches.match(SHELL_URL, { cacheName: SHELL });
    if (cached) return cached;
    throw err;
  }
}
