// SPDX-License-Identifier: AGPL-3.0-or-later
//
// どの OS の人が見ているか、の粗いヒント。
//
// 使うのは、UX 契約(docs/UX_CONTRACT.md)で「OS で本当に変わる」と
// 裏が取れた二つだけ ──
//   ・修飾キーが ⌘ か Ctrl か(Apple HIG の Keyboards / Microsoft の
//     Keyboard interactions)
//   ・指で押す大きさの目安(Android は 48dp、それ以外は 44)
// 見た目の方言(角の丸み、色、密度)には使わない。それは UI の話で、
// ここは UX の話。
//
// 根拠が薄いことを知ったうえで使う:
//   ・navigator.userAgentData.platform は実験的で、Baseline ではない
//     (MDN)。無い環境では userAgent の文字列で見る。
//   ・粗いヒントで、識別子ではない。端末の外には出さない。
//   ・間違えうるので、使う人が上書きできる(localStorage の OVERRIDE_KEY)。

export type Platform = 'mac' | 'windows' | 'android' | 'ios' | 'other';

export const OVERRIDE_KEY = 'sf.platform';

const PLATFORMS: readonly Platform[] = ['mac', 'windows', 'android', 'ios', 'other'];

export type Hints = {
  // navigator.userAgentData?.platform ("macOS" / "Windows" / "Android" …)
  uaDataPlatform?: string;
  userAgent?: string;
  maxTouchPoints?: number;
};

// 順番に意味がある。Android の userAgent には "Linux" が入り、iPad の
// "デスクトップ表示" は Mac を名乗る ── 先に確かな札から当てる。
export function detectPlatform({
  uaDataPlatform = '',
  userAgent = '',
  maxTouchPoints = 0
}: Hints): Platform {
  if (uaDataPlatform === 'Android' || /Android/i.test(userAgent)) return 'android';
  if (/iPhone|iPad|iPod/.test(userAgent)) return 'ios';
  if (uaDataPlatform === 'Windows' || /Windows/i.test(userAgent)) return 'windows';
  if (uaDataPlatform === 'macOS' || /Macintosh|Mac OS X/.test(userAgent)) {
    // タッチのある "Mac" は、デスクトップ表示の iPad。
    return maxTouchPoints > 1 ? 'ios' : 'mac';
  }
  return 'other';
}

// ⌘ を主にするのは Apple の機器。そこでは Control を修飾に使わない
// (システムが使う ── HIG)。それ以外は Ctrl。
export const usesCommandKey = (p: Platform): boolean => p === 'mac' || p === 'ios';

type ModKeys = Pick<KeyboardEvent, 'metaKey' | 'ctrlKey'>;

export function isPrimaryMod(e: ModKeys, p: Platform): boolean {
  return usesCommandKey(p) ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey;
}

// aria-keyshortcuts の綴り(WAI-ARIA は Meta / Control)。
export const shortcutOf = (key: string, p: Platform): string =>
  `${usesCommandKey(p) ? 'Meta' : 'Control'}+${key}`;

// ── ここから先は、ブラウザの中でだけ ──────────────────────────────

const isPlatform = (v: unknown): v is Platform => PLATFORMS.includes(v as Platform);

let cached: Platform | null = null;

function readOverride(): Platform | null {
  try {
    const v = localStorage.getItem(OVERRIDE_KEY);
    return isPlatform(v) ? v : null;
  } catch {
    return null; // 私的な窓などで読めなくても、動くこと
  }
}

export function platform(): Platform {
  if (cached) return cached;
  if (typeof navigator === 'undefined') return 'other';
  const nav = navigator as Navigator & { userAgentData?: { platform?: string } };
  cached =
    readOverride() ??
    detectPlatform({
      uaDataPlatform: nav.userAgentData?.platform,
      userAgent: nav.userAgent,
      maxTouchPoints: nav.maxTouchPoints
    });
  return cached;
}

// null で上書きを外す。<html data-platform> も更新する。
export function setPlatformOverride(p: Platform | null): void {
  try {
    if (p) localStorage.setItem(OVERRIDE_KEY, p);
    else localStorage.removeItem(OVERRIDE_KEY);
  } catch {
    // 書けなければ、この回かぎり
  }
  cached = p; // null なら、次に platform() が引き直す
  applyPlatform();
}

// CSS が読む。tokens.css の --tap-min が、これを見て 44 / 48 を選ぶ。
export function applyPlatform(): void {
  if (typeof document === 'undefined') return;
  document.documentElement.dataset.platform = platform();
}
