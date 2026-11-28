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

// あと3時間 / あと2日 / 終わっています。分までは言わない。
export function until(iso, now = new Date()) {
  if (!iso) return '';
  const mins = Math.floor((new Date(iso) - now) / 60_000);
  if (!(mins > 0)) return '終わっています';
  if (mins < 60) return `あと${mins}分`;
  if (mins < 24 * 60) return `あと${Math.floor(mins / 60)}時間`;
  return `あと${Math.floor(mins / (24 * 60))}日`;
}

// 制御の確認の結果を、ひとことで。
export function evidenceText(e) {
  if (!e) return 'まだ確かめていません';
  if (e.failure === 'unlinked') return '相手の頁に、この人へのつながりが見つかりません';
  if (e.failure) return `確かめられませんでした(${e.failure})`;
  return e.verified_at ? `確かめました(${ago(e.verified_at)})` : 'まだ確かめていません';
}

// #/applications/482913 → { name: 'read', receipt }
export function parse(hash) {
  const h = hash.replace(/^#/, '');
  const m = h.match(/^\/applications\/([^/]+)$/);
  if (m) return { name: 'read', receipt: decodeURIComponent(m[1]) };
  if (h === '/applications') return { name: 'list' };
  if (h === '/suspensions') return { name: 'suspensions' };
  return { name: 'public' };
}
