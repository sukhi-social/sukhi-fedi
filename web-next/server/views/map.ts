// SPDX-License-Identifier: AGPL-3.0-or-later
// この星の路線図。駅も線路も比喩だけれど、形は docs/ARCHITECTURE.md の実配線と一対一に対応させてある。
// 数字は公開の `GET /api/map` から ── この 1 日の数(note と、連合へ届けた便)。
// 1 日基準なのは、しずかな星でも「この星の一日」が見えるように。線路は、数字が取れなくても描ける。
//
// 全部、サーバで描く。ブラウザが 30 秒ごとに取りなおすとき(routes/map.ts の /map/live)は、
// 「領域(data-map-region)」ごとに、変わった所だけ差しかえる ── 列車が、そのたびに出発点へ戻らないように。
//   rail      線路の上の乗り物と、側線の貨車(線路そのものは動かない)
//   board     発車標
//   universe  連合の宇宙図(管理人が選んだ星が一つも無ければ、空)
// 領域の印(data-v)は、中身の HTML の指紋。同じなら、差しかえない。
//
// 動きを減らす設定(prefers-reduced-motion)は、CSS が見る。乗り物は「走る組」と「停めた組」を両方描いて、
// どちらを見せるかを CSS で選ぶ(JS が無くても、読み込みの瞬間にも、ちらつかない)。

import { createHash } from 'node:crypto';
import { html, type SafeHtml } from '../html.ts';
import type { Locale, T } from '../i18n.ts';
import { timeWords } from '../time.ts';

// ── 数 ────────────────────────────────────────────────────────────

export type MapSample = {
  at: string;
  /** 連合線の数字が取れているか(取れていなければ「運転見合わせ」)。 */
  fedRunning: boolean;
  /** DLQ 側線でとまっている数。取れなければ null。 */
  dlqHeld: number | null;
  local: number;
  remote: number;
  deliveries: number;
  peers: { domain: string; notes: number }[];
};

// 星は、管理人が allow-list に入れたものだけ(gateway が絞り済み)。それでも、置く手間が増えすぎないように。
const MAX_PEERS = 60;

const obj = (v: unknown): Record<string, unknown> => (typeof v === 'object' && v !== null ? (v as Record<string, unknown>) : {});
const count = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0);

/** gateway の返事を、この頁が読む形に。読めなければ null(= 「はかれなかった」)。 */
export function parseSample(raw: unknown): MapSample | null {
  const r = obj(raw);
  if (typeof r.at !== 'string' || Number.isNaN(Date.parse(r.at))) return null;
  const streams = obj(r.streams);
  const held = obj(streams.outbox_dlq).held;
  const notes = obj(r.notes_24h);
  const peers = (Array.isArray(r.peers) ? r.peers : [])
    .map((p) => ({ domain: obj(p).domain, notes: count(obj(p).notes_24h) }))
    .filter((p): p is { domain: string; notes: number } => typeof p.domain === 'string' && p.domain !== '')
    .slice(0, MAX_PEERS);
  return {
    at: r.at,
    fedRunning: typeof streams.outbox === 'object' && streams.outbox !== null,
    dlqHeld: typeof held === 'number' && Number.isFinite(held) ? count(held) : null,
    local: count(notes.local),
    remote: count(notes.remote),
    deliveries: count(r.deliveries_24h),
    peers
  };
}

/** 1 日の数 → 列車の本数。桁でゆっくり増える(1-9→1, 10-99→2, 100-999→3, …)。 */
export const trains = (n: number, max = 4): number => (n <= 0 ? 0 : Math.min(max, Math.floor(Math.log10(n)) + 1));

// ── 領域 ──────────────────────────────────────────────────────────

const stamp = (inner: SafeHtml): string => createHash('sha1').update(inner.value).digest('base64url').slice(0, 12);

// ── 星の置き場所 ──────────────────────────────────────────────────
// 星の位置は domain のハッシュが種 = いつ見ても同じ空。

export function starHash(s: string): number {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
  return h;
}

/** 星の大きさは、この 1 日にとどいた便りの桁で。 */
export const starSize = (n: number): number => (n <= 0 ? 3 : Math.min(9, 4.5 + Math.floor(Math.log10(n)) * 1.5));

/** 四つ角のきらめき(古い星図の星)。 */
function starPath(s: number): string {
  const k = s * 0.2;
  return `M 0 ${-s} Q ${k} ${-k} ${s} 0 Q ${k} ${k} 0 ${s} Q ${-k} ${k} ${-s} 0 Q ${-k} ${-k} 0 ${-s} Z`;
}

export type PlacedStar = { domain: string; notes: number; x: number; y: number };

/**
 * ラベルどうしが重ならないように、一つずつ置く。ぶつかったら、その星のハッシュ由来の角度から螺旋に外へ逃がす。
 * 順序も種も入力だけで決まるので、同じ星ぞろえなら空はいつも同じ形。
 */
export function placeStars(peers: { domain: string; notes: number }[]): PlacedStar[] {
  const placed: (PlacedStar & { w: number })[] = [];
  for (const p of peers) {
    const h = starHash(p.domain);
    let a = ((h % 360) * Math.PI) / 180;
    let r = 105 + ((h >>> 9) % 145);
    const w = p.domain.length * 6.6 + 16;
    let x = 480;
    let y = 215;
    for (let attempt = 0; attempt < 48; attempt++) {
      x = Math.round(Math.min(880, Math.max(80, 480 + Math.cos(a) * r * 1.5)));
      y = Math.round(Math.min(370, Math.max(60, 215 + Math.sin(a) * r * 0.72)));
      const collides =
        (Math.abs(480 - x) < w / 2 + 44 && Math.abs(215 - y) < 48) ||
        placed.some((q) => Math.abs(q.x - x) < (q.w + w) / 2 && Math.abs(q.y - y) < 32);
      if (!collides) break;
      a += 0.55;
      r += 13;
    }
    placed.push({ domain: p.domain, notes: p.notes, x, y, w });
  }
  return placed.map(({ w: _w, ...star }) => star);
}

// ── 乗り物 ────────────────────────────────────────────────────────
// 数は実流量から。線路の上は車輪つきの貨車、宇宙は小さなロケット。どれもゆったり。
// 動きを減らす設定のときは、隠すのではなく、道すじの途中に静かに停めて見せる
// (keyPoints を同値にピン留めした SMIL は、位置決めだけして動かない)。

function ride(path: string, dur: number, n: number, i: number, shuttle: boolean, still: boolean): SafeHtml {
  if (still) {
    const p = (i + 1) / (n + 1);
    return html`<animateMotion dur="1s" fill="freeze" rotate="auto" calcMode="linear" keyPoints="${p};${p}" keyTimes="0;1"><mpath href="${path}" /></animateMotion>`;
  }
  return html`<animateMotion dur="${dur}s" begin="${(-i * dur) / n}s" repeatCount="indefinite" rotate="auto" keyPoints="${shuttle ? '0;1;0' : '0;1'}" keyTimes="${shuttle ? '0;0.5;1' : '0;1'}" calcMode="linear"><mpath href="${path}" /></animateMotion>`;
}

type Shape = (ride: SafeHtml) => SafeHtml;

const boxcar = (cls: string): Shape => (m) => html`<g class="train ${cls}">
  <rect x="-6.5" y="-6.5" width="13" height="9" rx="2" />
  <circle class="wheel" cx="-3.5" cy="3.6" r="1.5" />
  <circle class="wheel" cx="3.5" cy="3.6" r="1.5" />
  ${m}</g>`;

const rocket: Shape = (m) => html`<g class="train build">
  <path d="M -5 0 L -9.5 -4.5 L -7.5 0 L -9.5 4.5 Z" />
  <path d="M -6.5 -3 H 1 Q 9 0 1 3 H -6.5 Z" />
  <circle class="window" cx="-1.5" cy="0" r="1.3" />
  ${m}</g>`;

// 新幹線は両頭(実物どおり)。WT は duplex なので往復運転が正確。
const shinkansen: Shape = (m) => html`<g class="train ink">
  <path d="M -12.5 0 Q -9 -3.5 -2 -3.5 H 2 Q 9 -3.5 12.5 0 Q 9 3.5 2 3.5 H -2 Q -9 3.5 -12.5 0 Z" />
  <rect class="window" x="-3.5" y="-2.2" width="7" height="1.7" rx="0.85" />
  ${m}</g>`;

const densha: Shape = (m) => html`<g class="train use">
  <rect x="-7" y="-6.5" width="14" height="9" rx="2.5" />
  <rect class="window" x="-4.6" y="-4.6" width="3.6" height="2.6" rx="0.9" />
  <rect class="window" x="1" y="-4.6" width="3.6" height="2.6" rx="0.9" />
  <circle class="wheel" cx="-3.8" cy="3.6" r="1.5" />
  <circle class="wheel" cx="3.8" cy="3.6" r="1.5" />
  ${m}</g>`;

const tram: Shape = (m) => html`<g class="train lr">
  <rect x="-5" y="-5" width="10" height="7" rx="2" />
  <rect class="window" x="-1.6" y="-3.2" width="3" height="2" rx="0.8" />
  <circle class="wheel" cx="-2.6" cy="3.2" r="1.2" />
  <circle class="wheel" cx="2.6" cy="3.2" r="1.2" />
  ${m}</g>`;

/** 走る組と停めた組(どちらを見せるかは CSS)。 */
class Fleet {
  readonly moving: SafeHtml[] = [];
  readonly parked: SafeHtml[] = [];
  add(shape: Shape, path: string, dur: number, n: number, shuttle = false): void {
    for (let i = 0; i < n; i++) {
      this.moving.push(shape(ride(path, dur, n, i, shuttle, false)));
      this.parked.push(shape(ride(path, dur, n, i, shuttle, true)));
    }
  }
  render(): SafeHtml {
    return html`<g class="map-moving">${this.moving}</g><g class="map-parked">${this.parked}</g>`;
  }
}

// ── 線路の上の乗り物(動く領域) ──────────────────────────────────

export function railRegion(s: MapSample | null): SafeHtml {
  const fleet = new Fleet();
  // 場内放送の中身は「新しい投稿のお知らせ」そのもの。実配線は plain NATS の stream.new_post(JetStream に載らず数を刻まない)なので、
  // 放送される中身 = この 1 日の note 数で数える。
  const newPosts = s ? s.local + s.remote : 0;
  // あなた→gateway はことばの電車、gateway→あなた は帰り専用の軽電鉄。在来線はどれもゆっくり。新幹線だけが、くらべて速い(ほぼ倍速)。
  fleet.add(densha, '#p-front', 28, s ? trains(s.local, 3) : 0);
  fleet.add(tram, '#p-lightrail', 30, trains(newPosts, 3));
  // 入りの便: ロケットが宇宙港に降りて、貨物急行の貨車に積み替わる。
  const fedIn = s ? trains(s.remote) : 0;
  fleet.add(rocket, '#p-route-in', 40, fedIn);
  fleet.add(boxcar('build'), '#p-express', 24, fedIn);
  // 出る便: delivery から貨車で発着場へ、そこからロケットで宇宙へ。
  const fedOut = s ? trains(s.deliveries) : 0;
  fleet.add(boxcar('build'), '#p-fedout-rail', 18, fedOut);
  fleet.add(rocket, '#p-route-out', 22, fedOut);
  // WT 新幹線の試運転列車。これだけは実流量ではなく「試運転中」という状態を描く一本(開業したら実数につなぎ替える)。duplex なので往復。
  fleet.add(shinkansen, '#p-wt', 44, 1, true);

  const held = s?.dlqHeld ? Array.from({ length: Math.min(s.dlqHeld, 3) }, (_, i) => html`<rect class="held-car" x="${800 + i * 10}" y="244" width="8" height="7" rx="2" />`) : [];
  const inner = html`${fleet.render()}${held}`;
  return html`<g data-map-region="rail" data-v="${stamp(inner)}">${inner}</g>`;
}

// ── 線路(動かない絵) ────────────────────────────────────────────

export function drawing(t: T, railRegionHtml: SafeHtml): SafeHtml {
  return html`<svg class="map-svg" viewBox="0 42 960 492" role="img" aria-label="${t('map.title')}">
    <!-- sukhi 中央駅の構内 -->
    <rect class="station-box" x="560" y="110" width="280" height="330" rx="8" />
    <text class="lbl lbl-bold" x="576" y="136">${t('map.sukhi')}</text>

    <!-- おもて口線(HTTPS): あなた → Cloudflare 宇宙港 → Anubis 検問所 → gateway -->
    <path id="p-front" class="track use" d="M 100 160 H 612" />
    <text class="line-name use" x="150" y="182">${t('map.lineFront')}</text>

    <!-- 場内放送の軽電鉄(SSE): gateway → あなた の専用ライン。行きの線とは別に、サーバから押し流す長生きのストリームが一本あるのは実配線どおり -->
    <path id="p-lightrail" class="track-light" d="M 612 152 Q 606 144 594 144 H 118 Q 108 144 103 152" />
    <text class="line-name muted" x="152" y="136">${t('map.lightRail')}</text>

    <!-- 進行方向の矢印。塗りの小さな三角を、線には乗せず、始点のわき・進行方向の右側に(この地図は右側通行 ── 対向線が左手にある配置)。WT だけは duplex なので両向きの一対 -->
    <path class="dir use" d="M 126 164.5 L 134 169 L 126 173.5 Z" />
    <path class="dir muted" d="M 552 132.5 L 544 137 L 552 141.5 Z" />
    <path class="dir build" d="M 326 176.5 L 334 181 L 326 185.5 Z" />
    <path class="dir build" d="M 796 340.5 L 804 345 L 796 349.5 Z" />
    <path class="dir build" d="M 863.5 320 L 868 311 L 872.5 320 Z" />
    <path class="dir build" d="M 840 84.5 L 831 89 L 840 93.5 Z" />
    <path class="dir ink" d="M 234 463.5 L 226 468 L 234 472.5 Z" />
    <path class="dir ink" d="M 242 463.5 L 250 468 L 242 472.5 Z" />

    <!-- 島のきわ。ここから先は連合宇宙(星は飾りだけれど、宇宙はほんとう) -->
    <path class="frontier" d="M 852 78 V 138 M 852 182 V 445" />
    <circle class="star" cx="925" cy="80" r="2" />
    <circle class="star" cx="945" cy="235" r="1.6" />
    <circle class="star" cx="935" cy="170" r="1.4" />
    <circle class="star" cx="900" cy="440" r="2" />
    <circle class="star" cx="940" cy="390" r="1.5" />

    <!-- 連合線(ActivityPub): 出は delivery から急行で発着場へ、そこから航路。入りは宇宙港(Cloudflare)に着いて、おもて口線で gateway へ -->
    <path id="p-fedout-rail" class="track build" d="M 779 336 H 842" />
    <path id="p-route-out" class="route" d="M 854 328 Q 888 246 879 132" />
    <!-- 入りの航路は、旅客の丸(宇宙港)ではなく貨物船ターミナルに降りる。港の上空を越えて、左まわりに四分円で降下して、ターミナルの左舷へ -->
    <path id="p-route-in" class="route" d="M 866 112 Q 560 20 300 100 Q 238 112 236 152 Q 234 190 271 196" />
    <!-- 貨物急行: 宇宙港に着いた連合の便は、Anubis の検問所に止まらず gateway へ。実配線どおり(/inbox 等は Anubis の素通しリスト)。検問所の下を抜ける複線 -->
    <!-- 宇宙港のすぐ下に貨物船ターミナル。線形は 宇宙港-(下)->ターミナル -(上右へ丸く)->gateway -->
    <path class="track build" d="M 280 174 V 189" />
    <path id="p-express" class="track build" d="M 287 196 Q 310 196 314 184 Q 317 172 336 172 H 588 Q 604 172 610 166" />
    <text class="line-name build" x="430" y="188">${t('map.express')}</text>
    <rect class="dock" x="273" y="190" width="14" height="14" rx="2" />
    <text class="lbl-sub" x="280" y="218" text-anchor="middle">${t('map.freightTerminal')}</text>
    <text class="line-name build" x="600" y="56">${t('map.lineFed')}</text>

    <!-- WT 新幹線(試運転中): あなた → karutte(x64) → WireGuard 専用線 → WT ホーム -->
    <path id="p-wt" class="track wt" d="M 100 166 V 480 H 578 Q 600 480 600 458 V 428" />
    <path class="hair" d="M 322 486 H 560" />
    <text class="line-name ink" x="150" y="470">${t('map.lineWt')}</text>
    <text class="chip-trial" x="440" y="470">${t('map.statusTrial')}</text>
    <text class="lbl-sub" x="440" y="502" text-anchor="middle">${t('map.wgTrunk')}</text>

    <!-- 構内連絡: gateway → api → NATS 操車場 → delivery、操車場 → WT ホーム -->
    <path class="hair" d="M 620 168 V 250 L 638 264" />
    <path class="hair" d="M 640 264 H 780 M 640 274 H 780 M 640 284 H 780" />
    <path class="hair" d="M 780 274 L 796 288 V 318 L 780 332" />
    <path class="hair" d="M 600 410 V 302 L 626 286" />
    <text class="lbl-sub" x="640" y="252">${t('map.yard')}</text>

    <!-- DLQ 側線: 操車場から右上へ。届かなかった列車が 30 日待つところ -->
    <path class="hair" d="M 780 264 L 800 248 H 828" />
    <path class="hair stop" d="M 828 242 V 254" />
    <text class="lbl-sub" x="806" y="236" text-anchor="middle">${t('map.siding')}</text>

    <!-- 駅たち -->
    <circle class="station terminus" cx="100" cy="160" r="8" />
    <text class="lbl" x="100" y="138" text-anchor="middle">${t('map.you')}</text>
    <!-- 宇宙港の敷地。旅客の丸から貨物船ターミナルまで、ひとつの枠で包む -->
    <rect class="port-ring" x="268" y="148" width="24" height="60" rx="12" />
    <circle class="station" cx="280" cy="160" r="6" />
    <text class="lbl" x="280" y="120" text-anchor="middle">${t('map.port')}</text>
    <!-- 検問所は駅(丸)ではなく、おもて口線をまたぐ関所のバー。下の貨物急行には届かない = 連合の便は検問を受けない -->
    <path class="checkpoint" d="M 450 151 V 169" />
    <text class="lbl" x="450" y="140" text-anchor="middle">${t('map.anubis')}</text>
    <circle class="station" cx="620" cy="160" r="6" />
    <text class="lbl" x="634" y="164">gateway</text>
    <circle class="station sm" cx="620" cy="215" r="5" />
    <text class="lbl" x="634" y="219">api</text>
    <circle class="station sm" cx="772" cy="336" r="5" />
    <text class="lbl" x="772" y="358" text-anchor="middle">delivery</text>
    <circle class="station sm" cx="600" cy="420" r="5" />
    <text class="lbl" x="614" y="424">${t('map.wtPlatform')}</text>
    <rect class="dock" x="844" y="330" width="12" height="12" rx="2" />
    <text class="lbl-sub" x="838" y="318" text-anchor="end">${t('map.dock')}</text>
    <circle class="station terminus" cx="880" cy="120" r="8" />
    <text class="lbl" x="880" y="152" text-anchor="middle">${t('map.fediverse')}</text>
    <text class="lbl-sub" x="880" y="168" text-anchor="middle">${t('map.fediverseSub')}</text>
    <circle class="station" cx="305" cy="480" r="6" />
    <text class="lbl" x="305" y="508" text-anchor="middle">${t('map.karutte')}</text>
    <text class="lbl-sub" x="305" y="523" text-anchor="middle">${t('map.karutteSub')}</text>

    ${railRegionHtml}
  </svg>`;
}

// ── 発車標 ────────────────────────────────────────────────────────
// 数字はぜんぶ本物、取れないときは取れないと言う。

export function boardRegion(t: T, locale: Locale, tz: string | undefined, s: MapSample | null): SafeHtml {
  const measuring = t('map.measuring');
  const running = t('map.statusRunning');
  const status = s == null ? measuring : s.fedRunning ? running : t('map.statusSuspended');
  const newPosts = s ? s.local + s.remote : null;
  const when = s ? timeWords(s.at, locale, new Date(), tz) : '';
  const inner = html`${when ? html`<p class="map-asof"><time datetime="${s?.at}">${t('map.boardAsOf', { time: when })}</time></p>` : ''}
    <ul class="map-board">
      <li>
        <span class="map-chip use">${t('map.lineFront')}</span>
        <span class="map-status">${running}</span>
        <p>${t('map.boardFront')} ${s ? t('map.boardFrontTrains', { n: s.local }) : ''}</p>
      </li>
      <li>
        <span class="map-chip build">${t('map.lineFed')}</span>
        <span class="map-status">${status}</span>
        <p>
          ${s == null ? measuring : t('map.boardFedOut', { n: s.deliveries })}
          ${s ? t('map.boardFedIn', { n: s.remote }) : ''}
          ${s?.dlqHeld == null ? '' : s.dlqHeld > 0 ? html`<span class="map-held">${t('map.boardSidingHeld', { n: s.dlqHeld })}</span>` : t('map.boardSidingEmpty')}
        </p>
      </li>
      <li>
        <span class="map-chip wt">${t('map.lineWt')}</span>
        <span class="map-status">${t('map.statusTrial')}</span>
        <p>${t('map.boardWt')}</p>
      </li>
      <li>
        <span class="map-chip muted">${t('map.lineEvents')}</span>
        <span class="map-status">${status}</span>
        <p>${newPosts == null ? measuring : t('map.boardEvents', { n: newPosts })}</p>
      </li>
    </ul>`;
  return html`<div data-map-region="board" data-v="${stamp(inner)}">${inner}</div>`;
}

// ── 連合の宇宙図 ──────────────────────────────────────────────────
// 載るのは管理人が allow-list に入れた星だけ(ホワイトリスト式)。まだ一つも選ばれていなければ、章ごと出さない(領域は空のまま残る)。

export function universeRegion(t: T, s: MapSample | null): SafeHtml {
  const stars = placeStars(s?.peers ?? []);
  let inner = html``;
  if (stars.length > 0) {
    // 便りのあった星からは、ロケットが sukhi へ飛んでくる(航路は 星→sukhi 向きに描く。rotate=auto は path の向きで機首を決めるので、逆走だと後ろ向き飛行になってしまう)。
    // 速さと発車時刻はハッシュ由来で、星ごとにすこしずつ違う。
    const lit = stars.flatMap((star, i) => (star.notes > 0 ? [{ star, i }] : []));
    const flight = (i: number, still: boolean): SafeHtml => {
      const h = starHash(stars[i].domain);
      return still
        ? html`<animateMotion dur="1s" fill="freeze" rotate="auto" calcMode="linear" keyPoints="0.6;0.6" keyTimes="0;1"><mpath href="#lane-${i}" /></animateMotion>`
        : html`<animateMotion dur="${20 + (h % 9)}s" begin="-${h % 17}s" repeatCount="indefinite" rotate="auto" keyPoints="0;1" keyTimes="0;1" calcMode="linear"><mpath href="#lane-${i}" /></animateMotion>`;
    };
    inner = html`<section class="section">
      <h2>${t('map.universeTitle')}</h2>
      <div class="map-scroll">
        <svg class="map-svg" viewBox="0 0 960 430" role="img" aria-label="${t('map.universeTitle')}">
          ${stars.map((star, i) => html`<path id="lane-${i}" class="lane" d="M ${star.x} ${star.y} L 480 215" />`)}
          <circle class="port-ring" cx="480" cy="215" r="13" />
          <circle class="station" cx="480" cy="215" r="6" />
          <text class="lbl" x="480" y="244" text-anchor="middle">sukhi</text>
          ${stars.map((star) => {
            const size = starSize(star.notes);
            return html`<g class="peer${star.notes > 0 ? ' lit' : ''}" transform="translate(${star.x} ${star.y})"><path d="${starPath(size)}" /></g>
              <text class="lbl-sub" x="${star.x}" y="${star.y + size + 14}" text-anchor="middle">${star.domain}</text>`;
          })}
          <g class="map-moving">${lit.map(({ i }) => rocket(flight(i, false)))}</g>
          <g class="map-parked">${lit.map(({ i }) => rocket(flight(i, true)))}</g>
        </svg>
      </div>
      <p class="prose-small map-note">${t('map.universeNote')}</p>
    </section>`;
  }
  return html`<div class="map-region" data-map-region="universe" data-v="${stamp(inner)}">${inner}</div>`;
}
