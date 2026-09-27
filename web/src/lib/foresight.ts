// SPDX-License-Identifier: AGPL-3.0-or-later
//
// リンクへ向かう「意図」を予測して、着く前にルートを温める。
//
// SvelteKit の hover 先読み(data-sveltekit-preload-data)は、ポインタが
// 要素に乗ってから動く。ここでは ForesightJS にマウスの軌道・キーボードの
// Tab・タッチ・スクロールを見せて、*乗る前* に preloadData を呼ぶ ──
// 速さは「1 手ぶん早い」から生まれる。
//
// 登録は一箇所。document を MutationObserver で見て、SPA の内部リンクを
// 片端から拾い、消えたら外す(外さないと、DOM から detach された要素は
// park されたまま掴まれ続ける ── 公式の Astro 連携も、消えたリンクは
// 外している)。これでナビも、投稿・プロフィール・記事・会話・リストも、
// 同じ一つの道を通る。リンクを足す人が、ここを思い出さなくていい。
//
// 温めるのは SvelteKit が持つルートだけ。/terms /privacy のように Elixir が
// 直に返す頁や /api /oauth /admin は SPA の外なので、そもそも登録しない。

import { ForesightManager } from 'js.foresight';
import { preloadData } from '$app/navigation';
import { isLoggedIn } from '$lib/auth';

// SvelteKit が持たない道。ここへ向かうリンクに preloadData を呼ぶと投げるので、
// 登録の時点で外す。
const NOT_APP = /^\/(?:api|oauth|admin|users|nodeinfo|proxy|uploads|static|twemoji|_app)(?:\/|$)/;
const NOT_APP_EXACT = new Set(['/terms', '/privacy', '/logout']);

let installed = false;

// 登録した anchor と、外す手。消えたノードのぶんを呼んで手放す。
const unregisterFor = new WeakMap<HTMLAnchorElement, () => void>();

// 温めてよいリンクか。外部・別タブ・ダウンロード・SPA の外は外す。
//
// 「いま居る頁」は**ここでは見ない**。登録は一度きりなので、登録時に現在地で
// 判断すると、その頁のリンク(ナビのホーム等)が二度と登録されない ──
// 別の頁へ移っても追跡されないままになる。現在地かどうかは、予測のたびに
// `warm` が見る。
function isPrefetchable(a: HTMLAnchorElement): boolean {
  if (!a.hasAttribute('href')) return false;
  if (a.hasAttribute('download') || a.hasAttribute('data-sveltekit-reload')) return false;

  const target = a.getAttribute('target');
  if (target && target !== '_self') return false;

  let url: URL;
  try {
    url = new URL(a.href, location.href);
  } catch {
    return false;
  }
  if (url.origin !== location.origin) return false;
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;

  const path = url.pathname;
  if (NOT_APP.test(path) || NOT_APP_EXACT.has(path)) return false;

  return true;
}

function warm(a: HTMLAnchorElement): void {
  // 予測のあとで href が変わっていることがある(動的なリンク)。閉じ込めた
  // URL ではなく、いま指している先を読み直す。
  if (!isPrefetchable(a)) return;
  // いま居る頁は、ルートもデータも既に手の中。温め直さない。これは
  // 予測のたびに見る ── 登録は一度きりで、現在地は動くから。
  try {
    if (new URL(a.href, location.href).pathname === location.pathname) return;
  } catch {
    return;
  }
  preloadData(a.href).catch(() => {
    // 温めは最善努力。失敗しても、クリックすればふつうに遷移する。
  });
}

function track(a: HTMLAnchorElement): void {
  if (unregisterFor.has(a)) return;
  if (!isPrefetchable(a)) return;
  const { unregister } = ForesightManager.instance.register({
    element: a,
    callback: () => warm(a)
  });
  unregisterFor.set(a, unregister);
}

function untrack(a: HTMLAnchorElement): void {
  const unregister = unregisterFor.get(a);
  if (!unregister) return;
  unregister();
  unregisterFor.delete(a);
}

function scan(root: ParentNode): void {
  if (root instanceof HTMLAnchorElement) track(root);
  for (const a of root.querySelectorAll('a')) {
    if (a instanceof HTMLAnchorElement) track(a);
  }
}

// layout から一度だけ呼ばれる。devAutoLogin() / registerServiceWorker() と
// 同じ、入口の一手。
export function installForesight(): void {
  if (installed) return;
  if (typeof window === 'undefined' || typeof document === 'undefined') return;
  // ログイン後のアプリでだけ入れる。未ログインの入口頁(/signup /check
  // /login)は途中で `location.assign` の全頁遷移をする ── 投機先読みが
  // 中断されやすく(Firefox は中断された import を console error に出す)、
  // 実益も薄い。アプリの中では予測がそのまま効く。
  if (!isLoggedIn()) return;
  installed = true;

  scan(document);

  const observer = new MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (node instanceof Element) scan(node);
      }
      for (const node of record.removedNodes) {
        if (!(node instanceof Element)) continue;
        if (node instanceof HTMLAnchorElement) untrack(node);
        for (const a of node.querySelectorAll('a')) {
          if (a instanceof HTMLAnchorElement) untrack(a);
        }
      }
    }
  });
  observer.observe(document.body, { childList: true, subtree: true });
}
