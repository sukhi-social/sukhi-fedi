// SPDX-License-Identifier: AGPL-3.0-or-later
const WEEK = ['月', '火', '水', '木', '金', '土', '日'];
export const weekdayChar = (n) => WEEK[n - 1] ?? '';
export const weekdayName = (n) => (WEEK[n - 1] ? WEEK[n - 1] + '曜日' : '');

// 482913 → 482 913(読み上げやすいように)
export const receiptText = (r) => String(r).replace(/^(\d{3})(\d{3})$/, '$1 $2');

// きのう / 2日前 など。今日のうちは「きょう」。
export function ago(iso, now = new Date()) {
  const days = Math.floor((now - new Date(iso)) / 86_400_000);
  if (!(days >= 0)) return '';
  return days === 0 ? 'きょう' : days === 1 ? 'きのう' : `${days}日前`;
}

// #/applications/482913 → { name: 'read', receipt }
export function parse(hash) {
  const h = hash.replace(/^#/, '');
  const m = h.match(/^\/applications\/([^/]+)$/);
  if (m) return { name: 'read', receipt: decodeURIComponent(m[1]) };
  if (h === '/applications') return { name: 'list' };
  return { name: 'public' };
}
