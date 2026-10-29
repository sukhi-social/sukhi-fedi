// SPDX-License-Identifier: AGPL-3.0-or-later
// 画像が無い人のアバター。
//
// サーバは「avatar は常に非 null の URL」という Mastodon の約束を守る
// ため、画像の無い人には既定の /static/avatar-default.svg(やさしい
// シルエット)を返す。web ではその URL を「画像なし」の印として受け取り、
// 頭文字 + 名前ごとの淡い色に描き替える ─ サーバ側の既定 URL
// (api の MastodonAccount.@default_avatar_path)とこの末尾を揃えること。

const DEFAULT_AVATAR_SUFFIX = '/avatar-default.svg'; // /static/avatar-default.svg(gateway)も、これで終わる

export function isDefaultAvatar(src: string | null | undefined): boolean {
  return !src || src.endsWith(DEFAULT_AVATAR_SUFFIX);
}

// 頭文字: 表示名(なければハンドル)の最初の一文字。絵文字や日本語も
// 一文字として取れるよう、コードポイント単位で先頭を取る。ラテン文字は
// 大文字に揃える。空のときだけ「?」。
export function avatarInitial(name: string): string {
  const trimmed = (name ?? '').trim();
  if (!trimmed) return '?';
  return Array.from(trimmed)[0].toUpperCase();
}

// 名前から淡い色をひとつ決める。同じ名前はいつも同じ色になるように、
// 文字コードを畳んで色相にする。彩度・明度は固定で、背景は淡く、
// 文字は同じ色相の濃いめ ─ うるさくならない範囲で見分けがつくように。
export function avatarColor(name: string): { bg: string; fg: string } {
  const s = name ?? '';
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360;
  return { bg: `hsl(${h} 45% 85%)`, fg: `hsl(${h} 40% 35%)` };
}
