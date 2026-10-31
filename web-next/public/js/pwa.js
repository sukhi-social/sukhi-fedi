// SPDX-License-Identifier: AGPL-3.0-or-later
// アプリらしさの、ブラウザ側。service worker をつなぐ・つながっていないときの帯・知らせ(push)の入り切り。
// 状態は、サーバにある。ここは、手元の動きだけ(app.js と同じ)。

// ── service worker ──────────────────────────────────────────────
// 名前は <meta name="application-name"> から。通知の題になる(sw/sw.js)。
if ("serviceWorker" in navigator) {
  const site =
    document.querySelector('meta[name="application-name"]')?.content ||
    "sukhi";
  addEventListener("load", () => {
    navigator.serviceWorker
      .register(`/sw?n=${encodeURIComponent(site)}`, { scope: "/" })
      .catch(() => {}); // 登録できなくても、ふつうの web として動く。
  });
}

// ── つながっていないときの帯 ──────────────────────────────────
// 頁を差し替えるのは Unpoly。fetch が届かなかったとき(up:fragment:offline)と、ブラウザが
// 「切れた」と言ったときに、<main> の外の帯を出す。いま見ている頁は、そのまま残す。
{
  const banner = document.getElementById("net-banner");
  let retry = null;

  // 帯の文は二つ。ネットワークが無い / サーバーが応えない。
  const show = (kind = "offline") => {
    if (!banner) return;
    for (const span of banner.querySelectorAll("[data-net]"))
      span.hidden = span.dataset.net !== kind;
    banner.hidden = false;
  };
  const hide = () => {
    if (banner) banner.hidden = true;
    retry = null;
  };

  up.on("up:fragment:offline", (event) => {
    retry = event.retry;
    show("offline");
  });

  // 前の proxy が 502/503/504 を返したとき。本文に <main> が無ければ(郵便局の頁ではない)、
  // Unpoly は差し替え先を見つけられず、何も起きないまま固まる。差し替えを止めて、帯と「もういちど」を出す。
  // 郵便局が自分で組んだ頁(<main> がある)は、これまでどおり差し替える。
  up.on("up:fragment:loaded", (event) => {
    const res = event.response;
    if (!res || ![502, 503, 504].includes(res.status)) return;
    if (/<main[\s>]/i.test(res.text || "")) return;
    event.preventDefault();
    retry = () => location.reload();
    show("server");
  });
  addEventListener("offline", () => show("offline"));
  addEventListener("online", hide);
  if (!navigator.onLine) show("offline");

  banner?.querySelector("button")?.addEventListener("click", () => {
    const again = retry;
    hide();
    if (again) again();
    else if (navigator.onLine) location.reload();
    else show("offline");
  });
}

// ── 出るとき ────────────────────────────────────────────────────
// この端末に置いたもの(読んだ頁・画像)と、この端末の知らせの購読を、片づけてから出る。
// 共用の端末で、次の人に前の人の頁や知らせが残らないように。
document.addEventListener(
  "submit",
  async (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    if (!form.getAttribute("action")?.startsWith("/logout")) return;
    event.preventDefault();
    try {
      await tidy();
    } catch {
      // 片づけきれなくても、出るのは止めない。
    }
    form.submit();
  },
  true,
);

async function tidy() {
  if ("caches" in window) {
    await Promise.all(
      ["sukhi-pages", "sukhi-media"].map((name) => caches.delete(name)),
    );
  }
  if (!("serviceWorker" in navigator)) return;
  const reg = await navigator.serviceWorker.getRegistration();
  const sub = await reg?.pushManager.getSubscription();
  if (!sub) return;
  // 先に郵便局へ(まだ入っているうちに)。この端末の購読のときだけ、gateway から外れる。
  await fetch("/push/unsubscribe", {
    method: "POST",
    body: new URLSearchParams({ endpoint: sub.endpoint }),
  }).catch(() => {});
  await sub.unsubscribe();
}

// ── 知らせ(push)────────────────────────────────────────────────
// 押しつけない ── 起動時に許可を訊かない。設定で、その人が入れたときだけブラウザに訊く
// (これは人を起こせる唯一の道。始めるのは、こちらではなく、その人の側)。
// 鳴っていい種類は gateway が決めていて、購読を置くのはサーバ(/push/subscribe)。ここは alerts を持たない。

// VAPID の公開鍵(base64url)を、subscribe() が求める生のバイト列にする。
// 一バイトずれても subscribe() は黙って通って、ただ何も鳴らなくなる。
function decodeServerKey(base64url) {
  const padded = base64url.padEnd(
    base64url.length + ((4 - (base64url.length % 4)) % 4),
    "=",
  );
  const raw = atob(padded.replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

const pushSupported = () =>
  "serviceWorker" in navigator &&
  "PushManager" in window &&
  "Notification" in window;

async function pushConfig() {
  const res = await fetch("/push/config", { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`push/config ${res.status}`);
  return res.json();
}

document.addEventListener("alpine:init", () => {
  // state: working / unsupported / unconfigured / denied / reauth / off / on
  Alpine.data("pushToggle", () => ({
    state: "working",
    failed: false,

    async init() {
      await this.refresh();
    },

    async refresh() {
      if (!pushSupported()) {
        this.state = "unsupported";
        return;
      }
      try {
        const c = await pushConfig();
        // 鍵の有無は、購読より先に。「やっていない」と「まだ購読していない」を、見分けるため。
        if (!c.configured) return void (this.state = "unconfigured");
        if (Notification.permission === "denied") return void (this.state = "denied");
        // 許可を訊く前に。あとで気づくと、取り返しのつかない一回を使い終えている。
        if (!c.scopeOk) return void (this.state = "reauth");
        const reg = await navigator.serviceWorker.getRegistration();
        const live = await reg?.pushManager.getSubscription();
        // サーバに行があっても、この端末の購読が消えていることがある。端末のほうを本当のこととする。
        this.state = c.endpoint && live && live.endpoint === c.endpoint ? "on" : "off";
      } catch {
        // 訊けなかっただけ。嘘の「入っています」より、もう一度押せるほうがいい。
        this.state = "off";
      }
    },

    async enable() {
      this.failed = false;
      this.state = "working";
      try {
        const permission = await Notification.requestPermission();
        if (permission !== "granted") {
          this.state = permission === "denied" ? "denied" : "off";
          return;
        }
        const reg = await navigator.serviceWorker.ready;
        // 鍵は取りなおす。古い鍵で購読すると、送っても復号できないまま静かに落ちる。
        const c = await pushConfig();
        if (!c.configured) return void (this.state = "unconfigured");

        const existing = await reg.pushManager.getSubscription();
        if (existing) await existing.unsubscribe();

        const sub = await reg.pushManager.subscribe({
          userVisibleOnly: true, // false は選べない ── 押すからには必ず見える。
          applicationServerKey: decodeServerKey(c.serverKey),
        });
        const json = sub.toJSON();
        const res = await fetch("/push/subscribe", {
          method: "POST",
          body: new URLSearchParams({
            endpoint: sub.endpoint,
            p256dh: json.keys?.p256dh ?? "",
            auth: json.keys?.auth ?? "",
          }),
        });
        if (!res.ok) {
          await sub.unsubscribe();
          throw new Error(`push/subscribe ${res.status}`);
        }
        this.state = "on";
      } catch {
        this.failed = true;
        this.state = "off";
      }
    },

    async disable() {
      this.failed = false;
      this.state = "working";
      try {
        const reg = await navigator.serviceWorker.getRegistration();
        const sub = await reg?.pushManager.getSubscription();
        if (sub) {
          await fetch("/push/unsubscribe", {
            method: "POST",
            body: new URLSearchParams({ endpoint: sub.endpoint }),
          }).catch(() => {});
          await sub.unsubscribe();
        }
      } catch {
        // 片方だけ落ちても、切ったことにする。残った行は、送ろうとしたときの 410 で消える。
      }
      this.state = "off";
    },
  }));
});
