// SPDX-License-Identifier: AGPL-3.0-or-later
// モックの頁に入る、ごく小さな足しもの。(shell の頁には、自動で入る)
//
//   ?s=fresh,night   場面。<html data-s="fresh night"> になる → CSS は html[data-s~=fresh] .x { … }、JS は lab.has('fresh')
//   ?now=22:30       時計。lab.now() がその時刻を返す(あいさつ・「次のお届け」のような、時で変わる所を確かめる)
//   ?theme=dark      明暗。light | dark(なければ端末まかせ)
//
// リンクと送信は、モックでは動かさない(行き先が無い)。押すと、行き先だけをそっと出す。
(() => {
  const q = new URLSearchParams(location.search);
  const root = document.documentElement;
  const flags = new Set((q.get('s') ?? '').split(',').filter(Boolean));
  root.dataset.s = [...flags].join(' ');
  if (q.get('theme') === 'dark' || q.get('theme') === 'light') root.dataset.theme = q.get('theme');

  const base = new Date();
  const at = (q.get('now') ?? '').match(/^(\d{1,2}):(\d{2})$/);
  const offset = at ? new Date(base).setHours(+at[1], +at[2], 0, 0) - base.getTime() : 0;

  let box;
  const toast = (text) => {
    box ??= Object.assign(document.body.appendChild(document.createElement('div')), { role: 'status' });
    box.textContent = text;
    box.style.cssText =
      'position:fixed;left:50%;bottom:76px;transform:translateX(-50%);z-index:99999;max-width:86vw;' +
      'padding:6px 12px;border-radius:999px;background:rgb(0 0 0/.72);color:#fff;font:12px/1.4 system-ui,sans-serif;pointer-events:none';
    clearTimeout(box._t);
    box._t = setTimeout(() => (box.style.display = 'none'), 1800);
    box.style.display = '';
  };

  window.lab = {
    has: (f) => flags.has(f),
    flags,
    now: () => new Date(Date.now() + offset),
    toast,
  };

  addEventListener(
    'click',
    (e) => {
      const a = e.target.closest?.('a[href]');
      if (!a || a.target === '_blank') return;
      const href = a.getAttribute('href');
      if (!href || href.startsWith('#') || !href.startsWith('/')) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      toast(`→ ${href}`);
    },
    true
  );
  addEventListener(
    'submit',
    (e) => {
      if (e.defaultPrevented) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      toast('(モック: 送りません)');
    },
    true
  );
})();
