// SPDX-License-Identifier: AGPL-3.0-or-later
// ブラウザ側は、これだけ。Unpoly の設定と、Alpine の小さな部品と、字の着替え。
// 状態は、サーバにある。ここにあるのは、開いたり閉じたりの、手元の動きだけ。

const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

// ── Unpoly ──────────────────────────────────────────────────────
// 頁の中身(<main>)を差し替える。リンクとフォームは、この郵便局の中のものだけ。
up.fragment.config.mainTargets = ["main"];
up.link.config.followSelectors.push('a[href^="/"]');
// ふつうのフォームも、Unpoly が <main> を差し替える。
up.form.config.submitSelectors.push("form");

// gateway が焼いた頁(規約など)・OAuth・API・ログアウトは、ふつうの遷移で。
// 入る(/login)・はじめる(/signup)のフォームも、ふつうの送信(フルリロード)にする。通ったあとは
// anubis の関所(/check)へ飛ぶが、あれは頁まるごとの HTML で、本物の遷移でないと JS が動かない。
// Unpoly の fetch で受けると <main> の差し替えになり、確認の画面が壊れる(2026-10-30)。
up.link.config.noFollowSelectors.push(
  'a[href^="/terms"]',
  'a[href^="/privacy"]',
  'a[href^="/oauth"]',
  'a[href^="/api"]',
  'a[href^="/settings/data/export"]',
);
up.form.config.noSubmitSelectors.push(
  'form[action^="/login"]',
  'form[action^="/signup"]',
  'form[action^="/logout"]',
  'form[action^="/oauth"]',
  'form[action^="/api"]',
  'form[action^="/lang"]',
);

// 先読みは、指が乗って少し経ってから。急がない。
up.link.config.preloadDelay = 200;

// ふわりとした遷移。動きを減らす設定なら、動かさない。
// (頁の差し替えは cross-fade が受け持ち、重なるモーダル(Layer)は Web Animations API が受け持つ。)
up.motion.config.enabled = !reduced;
up.fragment.config.navigateOptions.transition = "cross-fade";
up.fragment.config.navigateOptions.duration = 180;

// ── マクロ (HTML をすっきりと保つための作法) ────────────────────────
// その場差し替えの作法 (お気に入り・ブースト・しおり・フォロー・消去・通知など)。
// 直近のまとまり(.status, .notif, .account-row など)を探し、そこだけを静かに差し替える。
up.macro("[in-place]", (el) => {
  if (!el.hasAttribute("up-target")) {
    const card = el.closest(".status, .notif, .account-row, [data-in-place]");
    el.setAttribute(
      "up-target",
      card
        ? card.id
          ? `#${card.id}`
          : ".status, .notif, .account-row"
        : ":origin",
    );
  }
  if (!el.hasAttribute("up-fail-target")) {
    el.setAttribute("up-fail-target", el.getAttribute("up-target"));
  }
  if (!el.hasAttribute("up-history")) {
    el.setAttribute("up-history", "false");
  }
  if (!el.hasAttribute("up-scroll")) {
    el.setAttribute("up-scroll", "keep");
  }
  if (!el.hasAttribute("up-focus")) {
    el.setAttribute("up-focus", "keep");
  }
});

// モーダルの作法(下書き・詳細など、手元で開いてそっと閉じるもの)。
up.macro("[modal]", (el) => {
  el.setAttribute("up-layer", "new modal");
  el.setAttribute("up-history", "true");
  el.setAttribute("up-animation", "fade-in");
});

// 遷移したら、開いていたメニューを、そっと閉じる。
up.on("up:location:changed", () =>
  document.dispatchEvent(new Event("closemenus")),
);

// 「もっと読む」で足されたものは、ふわっと入る。
up.on("up:fragment:inserted", (_event, fragment) => {
  if (
    !reduced &&
    fragment instanceof Element &&
    fragment.closest('[id$="-items"]')
  ) {
    fragment.classList.add("up-soft-in");
  }
});

// ── Alpine ──────────────────────────────────────────────────────
document.addEventListener("alpine:init", () => {
  // 長い本文は、数行で畳んで「続きを読む」。背の高さで決める(記事かどうかを知らせる旗は無い)。
  Alpine.data("collapsible", ({ full = false } = {}) => ({
    tall: false,
    expanded: false,
    init() {
      if (full) return;
      this.$nextTick(() => {
        this.tall = this.$refs.content.scrollHeight > 360;
      });
    },
  }));
});

// ── どの OS か(粗いヒント)。--tap-min が、これを読む(docs/UX_CONTRACT.md)──
{
  const ua = navigator.userAgent;
  const platform = /Android/i.test(ua)
    ? "android"
    : /iPhone|iPad|iPod/i.test(ua) ||
        (/Macintosh/i.test(ua) && navigator.maxTouchPoints > 1)
      ? "ios"
      : /Macintosh/i.test(ua)
        ? "mac"
        : /Windows/i.test(ua)
          ? "windows"
          : "other";
  document.documentElement.dataset.platform = platform;
}

// ── 字を、ゆっくり着替える ──────────────────────────────────────
// Web フォントは、届くまで代わりの字で出て、届いたときに差し替わる。そのとき折り返しが変わると、
// 読んでいる段落が一行ずれる。だから、間に合ったときはすぐ、間に合わなかったときは、
// 画面が入れ替わる遷移のときに着替える(本文が丸ごと替わる瞬間は、ずれが見えない)。
{
  const IN_TIME_MS = 1200;
  const sheets = [
    `nunito/latin-400.css`,
    `nunito/latin-700.css`,
    `nunito/latin-ext-400.css`,
    `nunito/latin-ext-700.css`,
    `nunito/cyrillic-400.css`,
    `nunito/cyrillic-700.css`,
    `nunito/vietnamese-400.css`,
    `nunito/vietnamese-700.css`,
    `zen-maru-gothic/japanese-400.css`,
    `zen-maru-gothic/japanese-700.css`,
    `gothic-a1/korean-400.css`,
    `gothic-a1/korean-700.css`,
  ];

  let loaded = false;
  let dressed = false;
  const dress = () => {
    dressed = true;
    document.documentElement.dataset.fonts = "on";
  };

  const loading = Promise.all(
    sheets.map(
      (s) =>
        new Promise((resolve, reject) => {
          const link = document.createElement("link");
          link.rel = "stylesheet";
          link.href = `/assets/fonts/${s}`;
          link.onload = resolve;
          link.onerror = reject;
          document.head.append(link);
        }),
    ),
  )
    .then(() =>
      Promise.all([
        document.fonts.load("400 1em Nunito"),
        document.fonts.load("700 1em Nunito"),
        document.fonts.load(
          `400 1em "Zen Maru Gothic"`,
          "あいうえおかきくけこ玄関のこと",
        ),
        document.fonts.load(
          `700 1em "Zen Maru Gothic"`,
          "あいうえおかきくけこ玄関のこと",
        ),
        document.fonts.load(`400 1em "Gothic A1"`, "가나다라마바사아자차"),
        document.fonts.load(`700 1em "Gothic A1"`, "가나다라마바사아자차"),
      ]),
    )
    .then(
      () => {
        loaded = true;
        return true;
      },
      () => false,
    );

  const late = new Promise((r) => setTimeout(() => r(false), IN_TIME_MS));
  document.addEventListener("DOMContentLoaded", () => {
    Promise.race([loading, late]).then((inTime) => {
      if (inTime) dress();
    });
  });

  // 画面が入れ替わったら、届いていて、まだ着替えていなければ着替える。
  up.on("up:fragment:inserted", () => {
    if (loaded && !dressed) dress();
  });
}

// ── パスキーを足す(設定 › ログインと安全) ───────────────────────
// 認証器を呼べるのはブラウザだけ。サーバは options を渡し、できあがりを gateway に渡すだけ。
// 対応していないブラウザには、フォームを出さず、「対応していません」の一言のまま。
const b64uToBuf = (s) => {
  const b = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b + "=".repeat((4 - (b.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0)).buffer;
};
const bufToB64u = (buf) =>
  btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

async function post(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    credentials: "same-origin",
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.message || data.error || "failed");
  return data;
}

// 「もっと読む」の一つ先読み。リンクが画面の少し手前まで来たら、次の 1 頁だけを裏で取っておく。
// 押したら、取れている頁がすぐ付く。付いた頁には新しい「もっと読む」が現れるので、またその次の 1 頁だけ。
// 数を増やさないための決まり:
//   - 画面から遠いうちは取らない(IntersectionObserver で、1 画面ぶん手前から)。
//   - 裏のタブでは取らない(見えるようになってから)。
//   - 通信量を減らす設定(Save-Data)のときは取らない。
//   - 1 つのリンクにつき 1 回だけ(取れたら observer を外す)。
up.compiler("a.load-more", (link) => {
  if (navigator.connection?.saveData || !("IntersectionObserver" in window)) return;
  let near = false;
  let done = false;
  const go = () => {
    if (done || !near || document.hidden) return;
    done = true;
    io.disconnect();
    // 失敗しても何もしない(押したときに、ふつうに取りにいく)。
    up.link.preload(link).catch(() => {});
  };
  const io = new IntersectionObserver(
    (entries) => {
      near = entries[entries.length - 1].isIntersecting;
      go();
    },
    { rootMargin: "0px 0px 100% 0px" },
  );
  io.observe(link);
  document.addEventListener("visibilitychange", go);
  return () => {
    io.disconnect();
    document.removeEventListener("visibilitychange", go);
  };
});

up.compiler("form[data-passkey-add]", (form) => {
  if (!window.PublicKeyCredential) return;
  form.hidden = false;
  document.querySelector("[data-passkey-unsupported]")?.setAttribute("hidden", "");
  const errorEl = form.querySelector("[data-passkey-error]");
  const button = form.querySelector("button[type=submit]");

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (button.disabled) return;
    button.disabled = true;
    errorEl.hidden = true;
    try {
      const { ref, publicKey: o } = await post("/settings/security/passkeys/options", {});
      const cred = await navigator.credentials.create({
        publicKey: {
          ...o,
          challenge: b64uToBuf(o.challenge),
          user: { ...o.user, id: b64uToBuf(o.user.id) },
          excludeCredentials: (o.excludeCredentials ?? []).map((c) => ({
            type: "public-key",
            id: b64uToBuf(c.id),
          })),
        },
      });
      if (!cred) return;
      await post("/settings/security/passkeys", {
        ref,
        nickname: form.elements.nickname.value,
        attestation_object: bufToB64u(cred.response.attestationObject),
        client_data_json: bufToB64u(cred.response.clientDataJSON),
      });
      up.reload("main", { cache: false });
    } catch (e) {
      // 自分でやめたとき(NotAllowedError)は、何も言わない。
      if (e?.name === "NotAllowedError") return;
      errorEl.textContent = e?.message || "";
      errorEl.hidden = !errorEl.textContent;
    } finally {
      button.disabled = false;
    }
  });
});
