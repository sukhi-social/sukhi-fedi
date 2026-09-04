// 地図のリンクから、場所の名前と座標を取り出す。yum(yum.atfedi.de)の
// naver.js を Node に持ってきたもの ── 網に出るのは Naver の place id の
// ときだけで、あとはリンクの文字列を読むだけ。
//
// 受けるもの:
//   Google Maps   …/@35.1587,129.1604,15z  /  ?q=35.1587,129.1604
//   OpenStreetMap …#map=15/35.1587/129.1604
//   Naver         ?c=129.1604,35.1587,…(lng が先) / ?lat=&lng= / place id
//   素の "35.1587,129.1604"
//
// Naver は自分の地図アプリが叩く内部 API を、名乗ったまま(UA を偽らず)
// 叩く。Referer が無いと 403。嫌がられたら名指しで弾けるように、
// 正直な名前で行く。

import type { Place } from '$lib/api';

const UA = 'Mozilla/5.0 (compatible; travel.natadeco.com/0.1; +https://travel.natadeco.com/) a travel journal';

function plausible(lat: number, lng: number): boolean {
  return (
    Number.isFinite(lat) &&
    Number.isFinite(lng) &&
    Math.abs(lat) <= 90 &&
    Math.abs(lng) <= 180 &&
    !(lat === 0 && lng === 0)
  );
}

// 「35.1587,129.1604」と手で書かれたもの。緯度が先 ── 先の数が緯度に
// なれないなら、逆に書いたのだと読む。
export function parseBareCoords(text: string): { lat: number; lng: number } | null {
  const m = String(text ?? '').match(/(-?\d{1,3}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})/);
  if (!m) return null;
  let [lat, lng] = [Number(m[1]), Number(m[2])];
  if (Math.abs(lat) > 90 && Math.abs(lng) <= 90) [lat, lng] = [lng, lat];
  return plausible(lat, lng) ? { lat, lng } : null;
}

// リンクの中に座標が書いてあるなら、網に出ずに済む。
export function coordsFromUrl(href: string): { lat: number; lng: number } | null {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return null;
  }

  // Google: /maps/place/…/@35.1587,129.1604,15z
  const at = url.pathname.match(/@(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)/);
  if (at) {
    const lat = Number(at[1]);
    const lng = Number(at[2]);
    if (plausible(lat, lng)) return { lat, lng };
  }

  // OSM: #map=15/35.1587/129.1604
  const osm = url.hash.match(/map=\d+(?:\.\d+)?\/(-?\d{1,3}\.\d+)\/(-?\d{1,3}\.\d+)/);
  if (osm) {
    const lat = Number(osm[1]);
    const lng = Number(osm[2]);
    if (plausible(lat, lng)) return { lat, lng };
  }

  // Naver: ?c=129.1604,35.1587,15,0,0,0,dh(lng が先)
  const c = url.searchParams.get('c');
  if (c) {
    const [a, b] = c.split(',').map(Number);
    if (Number.isFinite(a) && Number.isFinite(b)) {
      const [lat, lng] = Math.abs(a) > 90 ? [b, a] : [a, b];
      if (plausible(lat, lng)) return { lat, lng };
    }
  }

  // ?lat=&lng= / ?lat=&lon= / ?y=&x=(Naver の x は経度) / Google の ?q=
  for (const [latKey, lngKey] of [
    ['lat', 'lng'],
    ['lat', 'lon'],
    ['y', 'x']
  ]) {
    const lat = Number(url.searchParams.get(latKey));
    const lng = Number(url.searchParams.get(lngKey));
    if (plausible(lat, lng)) return { lat, lng };
  }
  const q = url.searchParams.get('q') ?? url.searchParams.get('query') ?? url.searchParams.get('ll');
  if (q) {
    const bare = parseBareCoords(q);
    if (bare) return bare;
  }
  return null;
}

// Naver のリンクが指す place id(あれば)。
export function placeIdFrom(href: string): string | null {
  const s = String(href ?? '');
  const m =
    s.match(/\/(?:entry\/)?(?:place|restaurant|cafe|hairshop|hospital|accommodation|attraction|beauty)\/(\d{6,})/) ||
    s.match(/[?&]placeId=(\d{6,})/) ||
    (/naver/.test(s) ? s.match(/\/(\d{9,})(?:[/?#]|$)/) : null);
  return m ? m[1] : null;
}

// place id から名前と座標。`pagedesc` は、名前と点の両方を持つ唯一の口。
// Referer が要る ── これが無いと誰が名乗っても 403。
async function fromPlaceApi(id: string, signal: AbortSignal): Promise<Place | null> {
  const res = await fetch(`https://map.naver.com/p/api/place/pagedesc/${id}`, {
    headers: {
      'user-agent': UA,
      accept: 'application/json',
      referer: `https://map.naver.com/p/entry/place/${id}`
    },
    signal
  }).catch(() => null);
  if (!res?.ok) return null;

  const detail = ((await res.json().catch(() => null)) as { data?: { placeDetail?: { name?: string; coordinate?: { latitude?: unknown; longitude?: unknown } } } } | null)?.data?.placeDetail;
  const lat = Number(detail?.coordinate?.latitude);
  const lng = Number(detail?.coordinate?.longitude);
  if (!plausible(lat, lng)) return null;
  return {
    lat,
    lng,
    name: detail?.name ? String(detail.name).trim() : '',
    url: `https://map.naver.com/p/entry/place/${id}`
  };
}

// 短いリンク(naver.me、maps.app.goo.gl)は、ひらいた先に本当のリンクがある。
async function expand(href: string, signal: AbortSignal): Promise<string> {
  const res = await fetch(href, { redirect: 'follow', headers: { 'user-agent': UA }, signal }).catch(() => null);
  return res?.url ?? href;
}

// 名前が取れないとき、リンクの中の読める部分を名前にする(Google の
// /maps/place/海雲台/… のような)。無ければ空 ── 書く人が埋める。
function nameFromUrl(href: string): string {
  try {
    const url = new URL(href);
    const m = url.pathname.match(/\/place\/([^/@]+)/);
    if (m) return decodeURIComponent(m[1]).replace(/\+/g, ' ').trim().slice(0, 120);
  } catch {
    /* 名前は無くていい */
  }
  return '';
}

/**
 * 入口。リンク(か、素の座標)から場所を一つ。読めなければ null。
 *
 * 1. 文字列の中に座標があれば、そのまま(網に出ない)
 * 2. Naver の place id があれば、pagedesc に訊く
 * 3. 短いリンクなら、ひらいた先でもう一度 1 と 2
 */
export async function resolvePlace(text: string, signal: AbortSignal): Promise<Place | null> {
  const input = String(text ?? '').trim();
  if (!input) return null;

  const bare = /^https?:/i.test(input) ? null : parseBareCoords(input);
  if (bare) return { ...bare, name: '', url: '' };

  let href = input;
  for (let hop = 0; hop < 2; hop++) {
    const fromLink = coordsFromUrl(href);
    if (fromLink) return { ...fromLink, name: nameFromUrl(href), url: href };

    const id = placeIdFrom(href);
    if (id) return fromPlaceApi(id, signal);

    if (hop === 0 && /^https?:\/\/(naver\.me|maps\.app\.goo\.gl|goo\.gl|osm\.org)\//i.test(href)) {
      href = await expand(href, signal);
      continue;
    }
    break;
  }
  return null;
}
