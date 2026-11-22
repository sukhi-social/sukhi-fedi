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

  // 書く欄の手助け: 絵文字をカーソルに入れる / @ のあとの名前の候補(サーバが小さな HTML で返す)。
  // 候補は、押したときだけ入る。勝手には入れない。
  // 添付(整える・回す・切る・貼る・alt)は media.js の部品を、そのまま混ぜる。
  Alpine.data("composeAssist", ({ cw = false, draft = "", note = false, restored = false, s = {} } = {}) => ({
    ...window.sukhiMedia.mediaMixin(s),
    cw,
    hits: "",
    // 戻ってきた書きかけがあるとき(ふつうのノートは、サーバが戻して、ここへ true で来る。記事は、下の loadDraft が立てる)。
    restored,
    // 書きかけ(記事の題と本文)。この端末の localStorage にだけ置く ── 送らない。
    // 送信を押した時点で「送った」の印を付け、次に書く頁を開いたとき、その印のものは捨てる。
    // (送れなかった頁は、サーバが書いた中身を返すので、それでまた置きなおされる。)
    init() {
      if (draft) this.loadDraft();
    },
    draftRead() {
      try {
        return JSON.parse(localStorage.getItem("sukhi.draft." + draft) || "null");
      } catch {
        return null;
      }
    },
    draftWrite(v) {
      try {
        if (v) localStorage.setItem("sukhi.draft." + draft, JSON.stringify(v));
        else localStorage.removeItem("sukhi.draft." + draft);
      } catch {
        // 置けなくても、書くことは、できる。
      }
    },
    draftNow(sent) {
      const title = this.$refs.title ? this.$refs.title.value : "";
      const status = this.$refs.body.value;
      return title || status ? { title, status, sent } : null;
    },
    loadDraft() {
      if (this.draftNow(false)) {
        this.save();
        return;
      }
      const d = this.draftRead();
      if (!d) return;
      if (d.sent || !(d.title || d.status)) {
        this.draftWrite(null);
        return;
      }
      if (this.$refs.title) this.$refs.title.value = d.title || "";
      this.$refs.body.value = d.status || "";
      this.restored = true;
    },
    save() {
      this.draftWrite(this.draftNow(false));
    },
    sent() {
      this.draftWrite(this.draftNow(true));
    },
    discard() {
      if (this.$refs.title) this.$refs.title.value = "";
      this.$refs.body.value = "";
      this.draftWrite(null);
      this.restored = false;
      if (note) {
        // ふつうのノートは、注意書きとセンシティブも空に。サーバの書きかけも畳む。
        const f = this.$root.elements;
        if (f.spoiler_text) f.spoiler_text.value = "";
        if (f.sensitive) f.sensitive.checked = false;
        this.cw = false;
        this.holdSave();
        fetch("/compose/draft/discard", { method: "POST", credentials: "same-origin" }).catch(() => {});
      }
    },
    // ふつうのノートの書きかけ: gateway に置く(別の端末からも続けられる)。手を止めたあとに、そっと。
    // 置けなくても、書くことは、できる。
    saveNote() {
      if (!note || this.holding) return;
      const f = this.$root.elements;
      const q = new URLSearchParams({
        status: f.status.value,
        spoiler_text: this.cw && f.spoiler_text ? f.spoiler_text.value : "",
        visibility: f.visibility ? f.visibility.value : "public",
      });
      if (f.sensitive && f.sensitive.checked) q.set("sensitive", "1");
      fetch("/compose/draft", { method: "POST", body: q, credentials: "same-origin" }).catch(() => {});
    },
    // 送る・消すとき、少しのあいだ置かない。手を止める間合いのあとに、遅れて来た保存が、
    // サーバが畳んだ書きかけを、よみがえらせないように。
    holding: false,
    holdSave() {
      this.holding = true;
      setTimeout(() => (this.holding = false), 4000);
    },
    ins(text) {
      const el = this.$refs.body;
      el.setRangeText(text + " ", el.selectionStart, el.selectionEnd, "end");
      el.focus();
    },
    async suggest() {
      const el = this.$refs.body;
      const before = el.value.slice(0, el.selectionStart);
      const m = /(?:^|\s)@([\w.-]{1,30}(?:@[\w.-]*)?)$/.exec(before);
      if (!m) {
        this.hits = "";
        return;
      }
      try {
        const res = await fetch("/people/suggest?q=" + encodeURIComponent(m[1]), { credentials: "same-origin" });
        this.hits = res.ok ? await res.text() : "";
      } catch {
        this.hits = "";
      }
    },
    pick(event) {
      const b = event.target.closest("[data-acct]");
      if (!b) return;
      const el = this.$refs.body;
      const pos = el.selectionStart;
      const head = el.value.slice(0, pos).replace(/@[\w.-]*(?:@[\w.-]*)?$/, "@" + b.dataset.acct + " ");
      el.value = head + el.value.slice(pos);
      el.setSelectionRange(head.length, head.length);
      this.hits = "";
      el.focus();
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

// ── いまいる土地の時刻 ───────────────────────────────────────────
// 「今日の昼下がり」を決めるには、読む人の tz が要る。サーバには届かないので、cookie に置く。
// 置くのは tz の名前(Asia/Tokyo など)だけ。次の頁から効く。
try {
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (tz && !document.cookie.split("; ").includes("sukhi_tz=" + encodeURIComponent(tz))) {
    document.cookie =
      "sukhi_tz=" + encodeURIComponent(tz) + "; Path=/; Max-Age=31536000; SameSite=Lax";
  }
} catch {
  // tz が読めない端末は、言語の既定のまま。
}

// ── 字を、ゆっくり着替える ──────────────────────────────────────
// Web フォントは、届くまで代わりの字で出て、届いたときに差し替わる。そのとき折り返しが変わると、
// 読んでいる段落が一行ずれる。だから、間に合ったときはすぐ、間に合わなかったときは、
// 画面が入れ替わる遷移のときに着替える(本文が丸ごと替わる瞬間は、ずれが見えない)。
{
  const IN_TIME_MS = 1200;
  // どの字を読むかは、テーマ(<html data-theme>、server/theme.ts)が決める。
  //   about: Nunito + Zen Maru Gothic + Gothic A1(about.sukhi.social と同じ)
  //   ink:   Source Sans 3(web の「紙とインク」。日本語・韓国語は、手元の字)
  const FONTS = {
    about: {
      base: "/assets/fonts/",
      sheets: [
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
      ],
      probes: () => [
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
      ],
    },
    ink: {
      base: "/assets/fonts-variable/",
      sheets: [`source-sans-3/wght.css`],
      probes: () => [
        document.fonts.load(`400 1em "Source Sans 3 Variable"`),
        document.fonts.load(`700 1em "Source Sans 3 Variable"`),
      ],
    },
  };
  const { base, sheets, probes } =
    FONTS[document.documentElement.dataset.theme] ?? FONTS.about;

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
          link.href = `${base}${s}`;
          link.onload = resolve;
          link.onerror = reject;
          document.head.append(link);
        }),
    ),
  )
    .then(() => Promise.all(probes()))
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

// ── パスキーで入る(ログイン) ──────────────────────────────────────
// 保存してある鍵を、ブラウザが選ばせてくれる(名前を入れなくてよい)。通ったら、サーバが返した行き先(関所)へ。
up.compiler("[data-passkey-login]", (box) => {
  if (!window.PublicKeyCredential) return;
  box.hidden = false;
  const errorEl = box.querySelector("[data-passkey-error]");
  const button = box.querySelector("button");

  button.addEventListener("click", async () => {
    if (button.disabled) return;
    button.disabled = true;
    errorEl.hidden = true;
    try {
      const { ref, publicKey: o } = await post("/login/passkey/options", {});
      const cred = await navigator.credentials.get({
        publicKey: { ...o, challenge: b64uToBuf(o.challenge) },
      });
      if (!cred) return;
      const r = cred.response;
      const done = await post("/login/passkey", {
        ref,
        credential_id: cred.id,
        authenticator_data: bufToB64u(r.authenticatorData),
        signature: bufToB64u(r.signature),
        client_data_json: bufToB64u(r.clientDataJSON),
        user_handle: r.userHandle ? bufToB64u(r.userHandle) : null,
      });
      location.assign(done.redirect || "/");
    } catch (e) {
      if (e?.name === "NotAllowedError") return;
      errorEl.textContent = e?.message || "";
      errorEl.hidden = !errorEl.textContent;
    } finally {
      button.disabled = false;
    }
  });
});

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

// 静かな自動翻訳(docs/TRANSLATION_AUTO.md)。オンにした人の、母語以外の投稿だけ(サーバーが印を付ける)。
// 画面に 6 割ほど入って、700ms 留まったときだけ、その投稿の「訳を見る」の form を、自分で押す。
//   - 通りすぎただけの投稿には何もしない。先読みもしない(取っても読まれないものを、取らない)。
//   - 一度に一つ。続けて取るときは、少し間を置く。裏のタブ・Save-Data のときは、しない。
//   - うまくいかないときは、黙ってボタンのまま。混んでいる・応えないときは 60 秒お休み。
//     鍵・月の分の知らせ(data-tr-rest)や、この場所に訳し役がいないときは、ページを開き直すまでお休み。
//   - 押すのは form 自身(auto=1 を添えて)。返ってくるのは、手で押したときと同じ「訳の場所」。
const trAuto = (() => {
  const DWELL = 700;
  const GAP = 400;
  const PAUSE = 60_000;
  const queue = new Set();
  let running = false;
  let restUntil = 0;
  let rest = false;

  const ready = () => !rest && Date.now() >= restUntil && !document.hidden;

  async function drain() {
    if (running) return;
    running = true;
    try {
      while (queue.size > 0 && ready()) {
        const form = queue.values().next().value;
        queue.delete(form);
        // 待つあいだに、離れた・差し替わった・もう画面にない、なら、やめる。
        if (!form.isConnected || !form._trVisible) continue;
        const flag = form.elements.auto;
        if (flag) flag.value = "1";
        try {
          const result = await up.submit(form);
          const body = result?.fragments?.[0];
          if (body?.querySelector("[data-tr-rest]")) rest = true;
          const why = body?.getAttribute?.("data-tr-quiet");
          if (why === "busy" || why === "engine_unavailable" || why === "failed") restUntil = Date.now() + PAUSE;
          if (why === "disabled" || why === "auto_off") rest = true;
        } catch {
          restUntil = Date.now() + PAUSE;
        }
        await new Promise((r) => setTimeout(r, GAP));
      }
    } finally {
      running = false;
    }
  }
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) drain();
  });
  return {
    DWELL,
    add(form) {
      if (ready()) {
        queue.add(form);
        drain();
      }
    },
    drop(form) {
      queue.delete(form);
    },
  };
})();

up.compiler("form[data-tr-auto]", (form) => {
  if (navigator.connection?.saveData || !("IntersectionObserver" in window)) return;
  const card = form.closest(".status") ?? form;
  let timer = 0;
  const io = new IntersectionObserver(
    (entries) => {
      const e = entries[entries.length - 1];
      // 背の高い投稿は 6 割に届かない。画面の 6 割を占めていれば、見ているとみなす。
      const seen = e.isIntersecting && (e.intersectionRatio >= 0.6 || e.intersectionRect.height >= innerHeight * 0.6);
      form._trVisible = seen;
      clearTimeout(timer);
      if (seen) timer = setTimeout(() => trAuto.add(form), trAuto.DWELL);
      else trAuto.drop(form);
    },
    { threshold: [0, 0.25, 0.6, 1] },
  );
  io.observe(card);
  return () => {
    clearTimeout(timer);
    io.disconnect();
    trAuto.drop(form);
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

// ── 新着の帯 ────────────────────────────────────────────────────
// タイムラインの上の [data-fresh] は、隠れた帯。新しい投稿が届いていたら、そっと見せる。
// PWA にはリロードが無い(ふつうのブラウザなら、リロードしてもよい)ので、押せば読みなおす、帯を置く。
//
// ・訊くのは「あるか」だけ(数も中身も取らない)。列は、押されるまで動かさない。
// ・見えているときだけ、ゆっくり訊く。裏に回ったら止め、戻ったときに(間が空いていれば)すぐ一度。
// ・通信量を減らす設定(Save-Data)では、定期の問い合わせはしない。戻ったときの一度だけ。
// ・ホーム画面から開いた(display-mode: standalone)ときは、手動の更新が無いぶん、すこし短い間合い。
const standalone =
  matchMedia("(display-mode: standalone)").matches ||
  matchMedia("(display-mode: minimal-ui)").matches ||
  navigator.standalone === true;
document.documentElement.dataset.displayMode = standalone ? "standalone" : "browser";

up.compiler("[data-fresh]", (bar) => {
  const url = bar.dataset.fresh;
  const every = standalone ? 60_000 : 180_000;
  const quiet = navigator.connection?.saveData === true;
  let last = 0;
  let timer = null;
  let found = false;

  // 屋根の高さ。帯が、その下に貼りつく。
  const nav = document.querySelector(".app-nav");
  if (nav) document.documentElement.style.setProperty("--app-nav-h", `${nav.offsetHeight}px`);

  const ask = async () => {
    if (found || document.hidden || !navigator.onLine) return;
    last = Date.now();
    try {
      const res = await fetch(url, { credentials: "same-origin", cache: "no-store", headers: { accept: "application/json" } });
      if (res.status !== 200) return;
      found = true;
      bar.hidden = false;
      stop();
    } catch {
      // 届かなかったら、何もしない。次の間合いで、また。
    }
  };
  const start = () => {
    if (timer || found || quiet) return;
    timer = setInterval(ask, every);
  };
  const stop = () => {
    clearInterval(timer);
    timer = null;
  };
  const onVisible = () => {
    if (document.hidden) return stop();
    start();
    if (Date.now() - last > 30_000) ask();
  };
  document.addEventListener("visibilitychange", onVisible);
  addEventListener("online", onVisible);
  start();

  const button = bar.querySelector("button");
  const press = () => {
    bar.hidden = true;
    // いまの頁を取りなおして、いちばん上から。履歴は増やさない。
    up.reload("main", { cache: false, scroll: "reset" });
  };
  button.addEventListener("click", press);

  return () => {
    stop();
    document.removeEventListener("visibilitychange", onVisible);
    removeEventListener("online", onVisible);
    button.removeEventListener("click", press);
  };
});

// ── 通知のしるし ────────────────────────────────────────────────
// ベルの横の、数(direct)とかたち(ambient)。数え方はサーバ(server/notify.ts)。ここは取りにいって、置くだけ。
//
//   ・頁と頁の境(up:location:changed)で、ふたつとも数えなおす。ambient が動くのは、ここだけ
//     ── 流れてきても画面の前では動かさない。変化の瞬間を誰も見ないことが「景色」の条件だから。
//   ・direct の呼び鈴(SSE)が鳴ったら、数だけを取りなおす。切れて繋ぎ直したときも(切れていたぶんの回収)。
//     呼び鈴は荷物ではない ── 鳴ったと知るだけで、数は、いつもサーバに訊く。
//   ・通知の頁が開いたら(下の [data-mark-seen])「見た」を置いて、もう一度数える。
//
// 数えなおしは、いつも順番に。重なって飛ばさない(古い答えが、新しい答えのあとに着いて、数を戻さないように)。
up.compiler("[data-notif]", (nav) => {
  const url = nav.dataset.notif;
  const streamUrl = nav.dataset.notifStream;
  let queued = null; // 順番待ちの数えなおし("all" か "direct")。待っているあいだに増えても、一つにまとめる
  let running = false;

  const paint = async (parts) => {
    try {
      const res = await fetch(url, { credentials: "same-origin", cache: "no-store", headers: { accept: "text/html" } });
      if (!res.ok) return;
      const doc = new DOMParser().parseFromString(await res.text(), "text/html");
      for (const part of parts === "direct" ? ["direct"] : ["direct", "ambient"]) {
        for (const where of ["top", "bottom"]) {
          const id = `notif-${part}-${where}`;
          const next = doc.getElementById(id);
          const current = document.getElementById(id);
          if (next && current) current.replaceWith(next);
        }
      }
    } catch {
      // 取れなかったら、表示は前のまま。そっとしておく。
    }
  };
  const pull = async (parts) => {
    queued = queued === "all" || parts === "all" ? "all" : "direct";
    if (running) return;
    running = true;
    while (queued) {
      const next = queued;
      queued = null;
      await paint(next);
    }
    running = false;
  };

  const all = () => pull("all");
  const offLocation = up.on("up:location:changed", all);
  document.addEventListener("notif:refresh", all);
  all();

  // 呼び鈴。入っていなければ(401)、EventSource は繋ぎ直すのをやめる。ほかで切れたときは、ブラウザが繋ぎ直す。
  let bell = null;
  let opened = false;
  if (streamUrl && "EventSource" in window) {
    bell = new EventSource(streamUrl);
    bell.addEventListener("direct", () => pull("direct"));
    bell.addEventListener("open", () => {
      if (opened) pull("direct");
      opened = true;
    });
  }
  // 寝ていたタブに戻ってきたとき ── 裏にいるあいだに切れていることが多い。数を、もう一度訊く。
  const onVisible = () => {
    if (!document.hidden) pull("direct");
  };
  document.addEventListener("visibilitychange", onVisible);

  return () => {
    offLocation();
    document.removeEventListener("notif:refresh", all);
    document.removeEventListener("visibilitychange", onVisible);
    bell?.close();
  };
});

// 通知の頁が開いた。見に来たので、「ここまで見た」を置いて、ナビの数を戻す。
// 裏のタブで開いただけのときは、見られるまで待つ(まだ見ていないので)。
up.compiler("[data-mark-seen]", (el) => {
  const mark = () =>
    fetch(el.dataset.markSeen, { method: "POST", credentials: "same-origin" })
      .then(() => document.dispatchEvent(new Event("notif:refresh")))
      .catch(() => {});
  if (!document.hidden) {
    mark();
    return;
  }
  const onVisible = () => {
    if (document.hidden) return;
    document.removeEventListener("visibilitychange", onVisible);
    mark();
  };
  document.addEventListener("visibilitychange", onVisible);
  return () => document.removeEventListener("visibilitychange", onVisible);
});

// ふたりの部屋が開いているあいだの、呼び鈴。鳴ったら(部屋に何か起きたら)、ログだけを取りなおして差す。
//   ・呼び鈴は荷物ではない。中身は流れず、訊き直す ── 切れていたあいだのぶんも、これで埋まる。
//   ・60 秒の見直しは残す。管が死んでいることに、こちらからは気づけない(「静か」と見分けがつかない)ので、これが最後の砦。
//   ・裏に回ったら畳む(寝ている端末の電池を静かに減らす。裏では、誰も見ていない)。戻ったら、開いて、一度訊く。
//   ・書きかけの返事(フォーム)は動かさない。差すのは、この箱の中身だけ。
//   ・data-room-query があれば、取りなおしの問い合わせに足す(Clips は「頁を開いてから届いたぶんだけ」を訊く)。
up.compiler("[data-room-live]", (log) => {
  const base = log.dataset.roomLive;
  let last = null; // 最後に差した断片。同じなら差さない(描きなおしで、選んでいた字やスクロールの手がかりを乱さない)
  let running = false;
  let queued = false;

  const pull = async () => {
    queued = true;
    if (running) return;
    running = true;
    while (queued) {
      queued = false;
      try {
        const res = await fetch(`${base}/talk${log.dataset.roomQuery ?? ""}`, { credentials: "same-origin", cache: "no-store", headers: { accept: "text/html" } });
        if (res.ok) {
          const text = await res.text();
          if (text !== last) {
            last = text;
            log.innerHTML = text;
          }
        }
      } catch {
        // 取れなかったら、ログは前のまま。そっとしておく。
      }
    }
    running = false;
  };

  // 入っていない・部屋が無い(401・404)ときは、EventSource は繋ぎ直すのをやめる。ほかで切れたときは、ブラウザが繋ぎ直す。
  let bell = null;
  let opened = false;
  const open = () => {
    if (bell || !("EventSource" in window)) return;
    bell = new EventSource(`${base}/stream`);
    bell.addEventListener("poke", pull);
    bell.addEventListener("open", () => {
      if (opened) pull();
      opened = true;
    });
  };
  const close = () => {
    bell?.close();
    bell = null;
  };
  const onVisible = () => {
    if (document.hidden) {
      close();
      return;
    }
    opened = false; // 開いた「いま」の一回は、下の pull で訊く(二度訊かない)
    open();
    pull();
  };
  document.addEventListener("visibilitychange", onVisible);
  const timer = setInterval(() => {
    if (!document.hidden) pull();
  }, 60_000);
  if (!document.hidden) open();

  return () => {
    clearInterval(timer);
    document.removeEventListener("visibilitychange", onVisible);
    close();
  };
});

// 路線図。30 秒ごとに数字を取りなおして、変わった所(領域)だけを差しかえる。
//   ・列車は、差しかえると出発点へ戻ってしまう。だから、領域の印(data-v)が同じなら、さわらない。
//   ・裏に回ったら止める。戻ったら、すぐ一度取る。
//   ・取れなかったら、いまの絵のまま、一言(data-map-error)をそえる。取れたら、消す。
//   ・あとから差した <svg> の SMIL は、Chromium で動きだしてくれないことがある(時計は進むのに、絵が凍る)ので、
//     現れたら、時計をこつんと触って気づかせる。
up.compiler("[data-map-live]", (page) => {
  const url = page.dataset.mapLive;
  const error = page.querySelector("[data-map-error]");
  let running = false;

  const nudge = () =>
    setTimeout(() => {
      for (const svg of page.querySelectorAll("svg")) svg.setCurrentTime?.(svg.getCurrentTime());
    }, 120);

  const pull = async () => {
    if (running || document.hidden) return;
    running = true;
    try {
      const res = await fetch(url, { credentials: "same-origin", cache: "no-store", headers: { accept: "text/html" } });
      if (!res.ok) throw new Error(String(res.status));
      const doc = new DOMParser().parseFromString(await res.text(), "text/html");
      let changed = false;
      for (const next of doc.querySelectorAll("[data-map-region]")) {
        const here = page.querySelector(`[data-map-region="${next.dataset.mapRegion}"]`);
        if (!here || here.dataset.v === next.dataset.v) continue;
        here.replaceWith(document.importNode(next, true));
        changed = true;
      }
      if (error) error.hidden = true;
      if (changed) nudge();
    } catch {
      if (error) error.hidden = false;
    } finally {
      running = false;
    }
  };

  const onVisible = () => {
    if (!document.hidden) pull();
  };
  document.addEventListener("visibilitychange", onVisible);
  const timer = setInterval(pull, 30_000);
  nudge(); // はじめに描かれた絵も(Unpoly が差した頁は、あとから入った絵と同じ)
  return () => {
    clearInterval(timer);
    document.removeEventListener("visibilitychange", onVisible);
  };
});

// Clips。古い順に並ぶので、開いたら、いちばん新しい(下の)ところへ。
//   ・下まで読んでいる人のところへ新しいクリップが届いたら、下へ送る。上のほうを読んでいる人は、動かさない。
//   ・探しているとき・古いほうだけを開いたとき(data-clips-bottom が無いとき)は、頭のまま。
up.compiler("[data-clips]", (page) => {
  const toBottom = () => window.scrollTo({ top: document.documentElement.scrollHeight });
  if (!page.hasAttribute("data-clips-bottom")) return;
  requestAnimationFrame(toBottom);
  let stuck = true;
  const onScroll = () => {
    stuck = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 160;
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  const live = page.querySelector("#clips-new");
  const mo = live ? new MutationObserver(() => stuck && requestAnimationFrame(toBottom)) : null;
  mo?.observe(live, { childList: true });
  return () => {
    window.removeEventListener("scroll", onScroll);
    mo?.disconnect();
  };
});
