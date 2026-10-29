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
up.link.config.noFollowSelectors.push(
  'a[href^="/terms"]',
  'a[href^="/privacy"]',
  'a[href^="/oauth"]',
  'a[href^="/api"]',
);
up.form.config.noSubmitSelectors.push(
  'form[action^="/logout"]',
  'form[action^="/oauth"]',
  'form[action^="/api"]',
  'form[action^="/locale"]',
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
