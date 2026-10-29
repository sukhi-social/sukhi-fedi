// SPDX-License-Identifier: AGPL-3.0-or-later
// 時計の針を外した世界の、時間のことば。
//
// 分・秒は言わない。一日のうつろい(朝・昼下がり・宵・夜ふけ)と、日のへだたりで言う。
// 古いものほど、ざっくりと ── 「秋の夜ふけ」。いつ・何分前、より、そのとき在った景色。
//
// 時刻は閲覧者の側の「いま」で決まるので、tz を渡せるようにしてある(既定は Asia/Tokyo。
// 言語が ko のときは Asia/Seoul)。サーバに閲覧者の tz は届かないので、言語を手がかりにする。

import type { Locale } from './i18n.ts';

type Part = 'dawn' | 'morning' | 'noon' | 'afternoon' | 'dusk' | 'evening' | 'late';
type Season = 'spring' | 'summer' | 'autumn' | 'winter';

const TZ: Record<Locale, string> = { ja: 'Asia/Tokyo', ko: 'Asia/Seoul' };

// 時刻 → 一日のどのあたりか。境い目は、感覚で。
export function partOfDay(hour: number): Part {
  if (hour < 4 || hour >= 22) return 'late'; // 夜ふけ(日付をまたぐ前も、あとも)
  if (hour < 6) return 'dawn'; // 明けがた
  if (hour < 11) return 'morning'; // 朝
  if (hour < 13) return 'noon'; // 昼
  if (hour < 17) return 'afternoon'; // 昼下がり
  if (hour < 19) return 'dusk'; // 夕ぐれ
  if (hour < 22) return 'evening'; // 宵
  return 'late';
}

// 北半球の、暦の季節(3-5 春、6-8 夏、9-11 秋、12-2 冬)。
export function seasonOf(month1: number): Season {
  if (month1 >= 3 && month1 <= 5) return 'spring';
  if (month1 >= 6 && month1 <= 8) return 'summer';
  if (month1 >= 9 && month1 <= 11) return 'autumn';
  return 'winter';
}

const PART: Record<Locale, Record<Part, string>> = {
  ja: {
    dawn: '明けがた',
    morning: '朝',
    noon: 'お昼',
    afternoon: '昼下がり',
    dusk: '夕ぐれ',
    evening: '宵',
    late: '夜ふけ'
  },
  ko: {
    dawn: '새벽',
    morning: '아침',
    noon: '한낮',
    afternoon: '오후',
    dusk: '해질녘',
    evening: '저녁',
    late: '깊은 밤'
  }
};

const SEASON: Record<Locale, Record<Season, string>> = {
  ja: { spring: '春', summer: '夏', autumn: '秋', winter: '冬' },
  ko: { spring: '봄', summer: '여름', autumn: '가을', winter: '겨울' }
};

function zoned(d: Date, tz: string): { y: number; m: number; day: number; hour: number } {
  const p = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
    hour: 'numeric',
    hourCycle: 'h23'
  }).formatToParts(d);
  const n = (type: string) => Number(p.find((x) => x.type === type)?.value ?? 0);
  return { y: n('year'), m: n('month'), day: n('day'), hour: n('hour') };
}

// 暦の日の数(同じ日 = 0、昨日 = 1)。時刻でなく、日付で数える。
function dayGap(now: ReturnType<typeof zoned>, then: ReturnType<typeof zoned>): number {
  const a = Date.UTC(now.y, now.m - 1, now.day);
  const b = Date.UTC(then.y, then.m - 1, then.day);
  return Math.round((a - b) / 86_400_000);
}

/**
 * 日時を、うつろいのことばで。
 *   同じ日   「今日の昼下がり」
 *   昨日     「昨日の宵」
 *   一週間   「三日前の朝」→ 数は出さず「このあいだの朝」
 *   それ以前 「秋の夜ふけ」(同じ年) / 「去年の秋の夜ふけ」
 * `now` は試験のために渡せる。
 */
export function timeWords(iso: string, locale: Locale, now: Date = new Date()): string {
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return '';
  const tz = TZ[locale];
  const a = zoned(now, tz);
  const b = zoned(then, tz);
  const gap = dayGap(a, b);
  const part = PART[locale][partOfDay(b.hour)];

  // 未来の時刻(予約投稿など)は、「あとで」と言う。
  if (then.getTime() > now.getTime() + 60_000) {
    if (gap === 0) return locale === 'ja' ? `今日の${part}` : `오늘 ${part}`;
    return locale === 'ja' ? `あしたの${part}` : `내일 ${part}`;
  }

  if (gap <= 0) {
    // 同じ日。ついさっきは、時間帯を言わずに「いま」。
    if (now.getTime() - then.getTime() < 5 * 60_000) return locale === 'ja' ? 'いま' : '방금';
    return locale === 'ja' ? `今日の${part}` : `오늘 ${part}`;
  }
  if (gap === 1) return locale === 'ja' ? `昨日の${part}` : `어제 ${part}`;
  if (gap < 7) return locale === 'ja' ? `このあいだの${part}` : `며칠 전 ${part}`;

  const season = SEASON[locale][seasonOf(b.m)];
  if (a.y === b.y) return locale === 'ja' ? `${season}の${part}` : `${season} ${part}`;
  if (a.y - b.y === 1) return locale === 'ja' ? `去年の${season}の${part}` : `작년 ${season} ${part}`;
  return locale === 'ja' ? `${b.y}年の${season}` : `${b.y}년 ${season}`;
}

// 約四半刻 ── 「約」を付けて言う、見直しの余白のことば。
export function delayWords(min: number, locale: Locale): string {
  if (min <= 0) return locale === 'ja' ? 'すぐ' : '곧';
  if (min <= 20) return locale === 'ja' ? '約四半刻' : '약 15분쯤';
  if (min <= 45) return locale === 'ja' ? '半刻ほど' : '30분쯤';
  return locale === 'ja' ? '一刻ほど' : '한 시간쯤';
}
