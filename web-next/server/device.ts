// SPDX-License-Identifier: AGPL-3.0-or-later
// 「入っている端末」の一覧に出す、端末のことばと場所。User-Agent を「Firefox · Windows」の形にし、
// 内側のアドレス(docker・LAN)は「だいたいの場所」として出さない。

const BROWSERS: [RegExp, string][] = [
  [/\b(?:Edg|EdgA|EdgiOS)\//, 'Edge'],
  [/\bOPR\/|\bOpera\b/, 'Opera'],
  [/\bSamsungBrowser\//, 'Samsung Internet'],
  [/\b(?:Firefox|FxiOS)\//, 'Firefox'],
  [/\b(?:Chrome|CriOS|Chromium)\//, 'Chrome'],
  [/\bSafari\//, 'Safari']
];

const SYSTEMS: [RegExp, string][] = [
  [/\bWindows\b/, 'Windows'],
  [/\bAndroid\b/, 'Android'],
  [/\b(?:iPhone|iPad|iPod)\b/, 'iOS'],
  [/\bMac OS X\b|\bMacintosh\b/, 'macOS'],
  [/\bCrOS\b/, 'ChromeOS'],
  [/\bLinux\b|\bX11\b/, 'Linux']
];

// 読み取れたら「ブラウザ · OS」(片方だけでも)。読めなければ null(呼ぶほうが「不明な端末」を出す)。
// 古い記録の "node"(この郵便局の fetch の名前)は、端末の名前ではないので、読めないものとして扱う。
export function deviceLabel(ua: string | null | undefined): string | null {
  const s = (ua ?? '').trim();
  if (!s || /^node(?:$|[\s/])/i.test(s)) return null;
  const browser = BROWSERS.find(([re]) => re.test(s))?.[1];
  const system = SYSTEMS.find(([re]) => re.test(s))?.[1];
  const parts = [browser, system].filter(Boolean);
  return parts.length ? parts.join(' · ') : null;
}

// docker・LAN・ループバック・ULA/リンクローカル。gateway が丸めたあとの形(172.21.0.x / fd00:…)も拾う。
const PRIVATE = [
  /^10\./,
  /^127\./,
  /^192\.168\./,
  /^169\.254\./,
  /^172\.(?:1[6-9]|2\d|3[01])\./,
  /^(?:::1|fc|fd|fe80)/i
];

// 外から来た印の無い(内側の)アドレス・読めないものは null。
export function placeLabel(ip: string | null | undefined): string | null {
  const s = (ip ?? '').trim();
  if (!s || s === '?') return null;
  return PRIVATE.some((re) => re.test(s)) ? null : s;
}
