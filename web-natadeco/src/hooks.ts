import type { Reroute } from '@sveltejs/kit';
import { browser } from '$app/environment';
import { isTravelHost } from '$lib/site';

// travel.natadeco.com は「別の部屋」── 同じ家(同じ Node、同じ API)の
// 中で、玄関だけが違う。host を見て、その部屋の頁に道をつなぎ替える。
// `/d/[slug]/p/[id]` や `/login` は両方の玄関から同じ頁を使う。
const TRAVEL: Record<string, string> = {
  '/': '/travel',
  '/new': '/d/travel/new',
  '/map': '/travel/map',
  '/d/travel': '/travel'
};

// ブラウザでは、サーバが html に置いた印(hooks.server.ts)を優先する。
function inTravel(url: URL): boolean {
  if (browser && document.documentElement.dataset.site === 'travel') return true;
  return isTravelHost(url.hostname);
}

export const reroute: Reroute = ({ url }) => {
  if (!inTravel(url)) return;
  return TRAVEL[url.pathname];
};
