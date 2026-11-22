// SPDX-License-Identifier: AGPL-3.0-or-later
// 見た目のテーマ。運営(サーバー)が、環境変数 SITE_THEME で選ぶ。ひとつの道が、ひとつの場所を通る ──
// テーマの名前・上に重ねる css・紙の色(<meta theme-color> と manifest)は、ここだけが知っている。
//
//   about   about.sukhi.social の色。クリーム色の紙・茶色の墨・橙がひとつ。既定(これまでの見た目)。
//   ink     web(SvelteKit の SPA)の「紙とインク」。飾りの色がなく、リンクは墨に下線。
//           css は public/css/theme-ink.css(tokens と、about の字間の打ち消し)。
//
// テーマは、<html data-theme="…"> に置く。css は、その属性の下だけで効く。
// 紙の色(color)は、css の --color-bg と同じ値を、ここにも書く(manifest は css の変数を読めない)。
// 変えるときは theme-ink.css の --color-bg と、ここの二か所をいっしょに。

export const THEMES = {
  about: { css: null, color: { light: '#fffaf3', dark: '#1f1915' } },
  ink: { css: '/assets/css/theme-ink.css', color: { light: '#efeee7', dark: '#1c1b18' } }
} as const satisfies Record<string, { css: string | null; color: { light: string; dark: string } }>;

export type ThemeName = keyof typeof THEMES;

export const DEFAULT_THEME: ThemeName = 'about';

// 知らない名前は、既定に戻す(打ち間違いで、頁が崩れないように)。
export function parseTheme(raw: string | undefined): ThemeName {
  const name = (raw ?? '').trim().toLowerCase();
  return Object.hasOwn(THEMES, name) ? (name as ThemeName) : DEFAULT_THEME;
}

// manifest(public/manifest.webmanifest)の、紙の色だけをテーマに合わせる。
// ほかは、そのまま。読めないものは、手を入れずに返す。
export function themedManifest(raw: string, theme: ThemeName): string {
  try {
    const m = JSON.parse(raw) as Record<string, unknown>;
    m.background_color = THEMES[theme].color.light;
    m.theme_color = THEMES[theme].color.light;
    return JSON.stringify(m, null, 2);
  } catch {
    return raw;
  }
}
