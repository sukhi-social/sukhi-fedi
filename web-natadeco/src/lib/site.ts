// どの玄関から来たか。natadeco.com の板と、travel.natadeco.com の旅の
// 記録は、同じ家の別の部屋 ── 中身は同じ API で、見せかたが違う。
export type Site = 'natadeco' | 'travel';

// 旅の記録が載っている板の slug。admin が一枚だけ立てる。
export const TRAVEL_SLUG = 'travel';

export function isTravelHost(hostname: string): boolean {
  return hostname === 'travel.natadeco.com' || hostname.startsWith('travel.');
}

export function siteOf(hostname: string): Site {
  return isTravelHost(hostname) ? 'travel' : 'natadeco';
}
