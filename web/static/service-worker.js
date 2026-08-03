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
