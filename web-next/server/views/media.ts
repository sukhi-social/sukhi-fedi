// SPDX-License-Identifier: AGPL-3.0-or-later
// 画像を整える部品(public/js/media.js)に渡す、ことばと決まり。
// ブラウザは辞書を持たないので、サーバーが言語を選んで、JSON にして属性にのせる。

import type { T } from '../i18n.ts';

// 一回の投稿に付けられる枚数。gateway も 4 枚まで。送る側(write.ts)も、整える側(media.js)も、これに合わせる
// (media.js へは、mediaStrings の max で渡す)。
export const MAX_ATTACHMENTS = 4;

// 書く欄で使うことば。{n} は、ブラウザが埋める(貼った枚数)ので、そのまま残す。
export function mediaStrings(t: T): Record<string, string> {
  return {
    max: String(MAX_ATTACHMENTS),
    zoom: t('crop.zoom'),
    hint: t('crop.hint'),
    cancel: t('crop.cancel'),
    confirm: t('crop.confirm'),
    keep: t('crop.keep'),
    original: t('crop.original'),
    cropTitle: t('crop.postTitle'),
    maxFiles: t('compose.maxFiles', { max: MAX_ATTACHMENTS }),
    pasted: t('compose.pasted', { n: '{n}', max: MAX_ATTACHMENTS }),
    prepFailed: t('compose.prepFailed')
  };
}

// 設定の、アイコンとヘッダーの切り抜き(アイコン 512 角の PNG、ヘッダー 3:1 の JPEG)。
export function cropSpec(t: T, kind: 'avatar' | 'header'): string {
  const base = { zoom: t('crop.zoom'), hint: t('crop.hint'), cancel: t('crop.cancel'), confirm: t('crop.confirm'), keep: t('crop.keep'), original: t('crop.original') };
  return JSON.stringify(
    kind === 'avatar'
      ? { ratio: 1, w: 512, h: 512, type: 'image/png', title: t('crop.avatarTitle'), s: base }
      : { ratio: 3, w: 1500, h: 500, type: 'image/jpeg', title: t('crop.headerTitle'), s: base }
  );
}
