// 明るい/暗いの明示切り替え。選ばなければ端末の設定のまま(app.html の
// 先読みスクリプトと同じ鍵)。

import { browser } from '$app/environment';

const KEY = 'nd.theme';

export type Theme = 'light' | 'dark';

// いま画面に出ている色。明示の指定があればそれ、無ければ端末の設定。
export function currentTheme(): Theme {
  if (!browser) return 'light';
  const stored = localStorage.getItem(KEY);
  if (stored === 'light' || stored === 'dark') return stored;
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

export function setTheme(t: Theme): void {
  if (!browser) return;
  localStorage.setItem(KEY, t);
  document.documentElement.dataset.theme = t;
}

export function toggleTheme(): Theme {
  const next: Theme = currentTheme() === 'dark' ? 'light' : 'dark';
  setTheme(next);
  return next;
}
