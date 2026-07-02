// タイムラインを出す前に、載る顔(アバター)を先に温める。
//
// 初回描画は短い予算(1 秒)だけ待って「投稿と顔が一緒に現れる」を狙う。
// 間に合わなければそのまま出して、あとは lazy に任せる ── 低帯域の人の
// 文字まで遅らせない。「もっと読む」の先読みも同じ関数で、本文と一緒に
// 顔も温めておく(押した瞬間、顔ごと揃って差し込まれる)。
//
// 温めは画面外の <picture> で行う。実際の描画(Avatar.svelte)と同じ
// 要素なので、ブラウザが選ぶ variant(avif / webp / 原本)と必ず同じ
// URL が温まる ── 検出コードで当てにいくより、ずれない。

import type { Status } from '$lib/api';
import { isDefaultAvatar } from '$lib/avatar';
import { proxyVariants } from '$lib/proxyImage';

// 一度に温める上限。1 ページ(20 投稿)の顔ぶれには十分で、
// 変な API 応答が来ても際限なくリクエストを撒かない。
const MAX_WARM = 40;

export function warmAvatars(statuses: Status[], budgetMs: number): Promise<void> {
  const urls: string[] = [];
  const seen = new Set<string>();
  const add = (src: string | null | undefined) => {
    // 既定アバターは頭文字に描き替えるので、画像としては温めない。
    if (!src || seen.has(src) || isDefaultAvatar(src)) return;
    seen.add(src);
    urls.push(src);
  };

  for (const s of statuses) {
    add(s.account?.avatar);
    add(s.reblog?.account?.avatar);
    add(s.quote?.account?.avatar);
  }

  if (urls.length === 0) return Promise.resolve();

  const host = document.createElement('div');
  host.style.cssText = 'position:absolute;width:0;height:0;overflow:hidden;';
  document.body.appendChild(host);

  const loads = urls.slice(0, MAX_WARM).map(
    (src) =>
      new Promise<void>((resolve) => {
        const v = proxyVariants(src);
        const pic = document.createElement('picture');
        if (v) {
          for (const [type, srcset] of [
            ['image/avif', v.avif],
            ['image/webp', v.webp]
          ] as const) {
            const source = document.createElement('source');
            source.type = type;
            source.srcset = srcset;
            pic.appendChild(source);
          }
        }
        const img = document.createElement('img');
        img.onload = () => resolve();
        img.onerror = () => resolve();
        pic.appendChild(img);
        host.appendChild(pic);
        img.src = src;
      })
  );

  // 片づけは「全部済んだら」。予算切れで先に描画へ進んでも読み込みは
  // 続けて、cache に入れておく(実描画の同じ URL がそれを拾う)。
  const done = Promise.all(loads).then(() => undefined);
  void done.finally(() => host.remove());

  return Promise.race([done, new Promise<void>((r) => setTimeout(r, budgetMs))]);
}
