// SPDX-License-Identifier: AGPL-3.0-or-later
// 時計の針を外した世界の、時間のことば。
//
// 分・秒は言わない。一日のうつろい(朝・昼下がり・宵・夜ふけ)と、日のへだたりで言う。
// 古いものほど、ざっくりと ── 「秋の夜ふけ」。いつ・何分前、より、そのとき在った景色。
//
// 時刻は閲覧者の側の「いま」で決まるので、tz を渡せる。サーバに閲覧者の tz は直接は届かないので、
// ① ブラウザが cookie(sukhi_tz)に置いたもの ② 無ければ言語を手がかりに(ja は Asia/Tokyo、
// ko は Asia/Seoul、en は UTC ── 英語の人は世界じゅうにいるので、決め打ちしない)。
// 季節は、南半球の tz なら半年ずらす(「秋の夜ふけ」が、春の人に届かないように)。

import type { Locale } from './i18n.ts';

type Part = 'dawn' | 'morning' | 'noon' | 'afternoon' | 'dusk' | 'evening' | 'late';
type Season = 'spring' | 'summer' | 'autumn' | 'winter';

const TZ: Record<Locale, string> = { ja: 'Asia/Tokyo', ko: 'Asia/Seoul', en: 'UTC' };

// cookie に置かれた tz が、ほんとうに使える名前か。使えなければ無し(言語の既定にもどる)。
export function validTz(v: string | null | undefined): string | undefined {
  if (!v || v.length > 64) return undefined;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: v });
    return v;
  } catch {
    return undefined;
  }
}

// 南半球の tz(季節が逆)。赤道をまたぐ国は、人の多い側に寄せている。
const SOUTH = /^(Australia\/|Pacific\/(Auckland|Fiji|Tongatapu|Apia|Chatham|Noumea|Port_Moresby)|Antarctica\/|Indian\/(Mauritius|Reunion|Antananarivo)|America\/(Sao_Paulo|Argentina\/|Santiago|Lima|La_Paz|Asuncion|Montevideo|Bahia|Fortaleza|Recife|Manaus|Cuiaba|Campo_Grande|Belem|Maceio)|Africa\/(Johannesburg|Maputo|Harare|Lusaka|Windhoek|Gaborone|Maseru|Mbabane|Luanda|Lubumbashi|Kinshasa|Dar_es_Salaam|Nairobi))/;
export function isSouthern(tz: string): boolean {
  return SOUTH.test(tz);
}


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
export function seasonOf(month1: number, southern = false): Season {
  const m = southern ? ((month1 + 5) % 12) + 1 : month1; // 南半球は半年ずらす
  if (m >= 3 && m <= 5) return 'spring';
  if (m >= 6 && m <= 8) return 'summer';
  if (m >= 9 && m <= 11) return 'autumn';
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
  },
  // 英語は、ことばを継ぎ足さず、日の景色ごと言い切る(下の ENGLISH)。ここは使わない。
  en: {
    dawn: 'dawn',
    morning: 'morning',
    noon: 'midday',
    afternoon: 'afternoon',
    dusk: 'dusk',
    evening: 'evening',
    late: 'night'
  }
};

const SEASON: Record<Locale, Record<Season, string>> = {
  ja: { spring: '春', summer: '夏', autumn: '秋', winter: '冬' },
  ko: { spring: '봄', summer: '여름', autumn: '가을', winter: '겨울' },
  en: { spring: 'spring', summer: 'summer', autumn: 'autumn', winter: 'winter' }
};

// 英語は、言い回しが時間帯ごとに変わる("this morning" / "at midday" / "late at night")ので、
// 継ぎ足しでなく、一語一語の表で持つ。分・秒を言わないのは、ほかの言語と同じ。
const EN: Record<'today' | 'yesterday' | 'tomorrow' | 'lately', Record<Part, string>> = {
  today: {
    dawn: 'at dawn',
    morning: 'this morning',
    noon: 'around midday',
    afternoon: 'this afternoon',
    dusk: 'at dusk',
    evening: 'this evening',
    late: 'late tonight'
  },
  yesterday: {
    dawn: 'yesterday at dawn',
    morning: 'yesterday morning',
    noon: 'yesterday around midday',
    afternoon: 'yesterday afternoon',
    dusk: 'yesterday at dusk',
    evening: 'yesterday evening',
    late: 'late last night'
  },
  tomorrow: {
    dawn: 'tomorrow at dawn',
    morning: 'tomorrow morning',
    noon: 'tomorrow around midday',
    afternoon: 'tomorrow afternoon',
    dusk: 'tomorrow at dusk',
    evening: 'tomorrow evening',
    late: 'late tomorrow night'
  },
  // 数日前。数は言わない("the other morning" は、ちょうどそういう言い方)。
  lately: {
    dawn: 'the other day, at dawn',
    morning: 'the other morning',
    noon: 'the other day, around midday',
    afternoon: 'the other afternoon',
    dusk: 'the other day, at dusk',
    evening: 'the other evening',
    late: 'the other night'
  }
};

const aOrAn = (word: string) => (/^[aeiou]/.test(word) ? 'an' : 'a');

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

// 暦の日付(閲覧者の側の tz)。「ことば」が何日分をまとめていても、日付は日付。
export function dayKey(iso: string, locale: Locale, tz?: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const z = zoned(d, tz ?? TZ[locale]);
  return `${z.y}-${z.m}-${z.day}`;
}

/**
 * 日時を、うつろいのことばで。
 *   同じ日   「今日の昼下がり」
 *   昨日     「昨日の宵」
 *   一週間   「三日前の朝」→ 数は出さず「このあいだの朝」
 *   それ以前 「秋の夜ふけ」(同じ年) / 「去年の秋の夜ふけ」
 * `now` は試験のために渡せる。
 */
export function timeWords(iso: string, locale: Locale, now: Date = new Date(), tzOverride?: string): string {
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return '';
  const tz = tzOverride ?? TZ[locale];
  const a = zoned(now, tz);
  const b = zoned(then, tz);
  const gap = dayGap(a, b);
  const partKey = partOfDay(b.hour);
  const part = PART[locale][partKey];
  if (locale === 'en') return englishWords(then, now, a, b, gap, partKey, isSouthern(tz));

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

  const season = SEASON[locale][seasonOf(b.m, isSouthern(tz))];
  if (a.y === b.y) return locale === 'ja' ? `${season}の${part}` : `${season} ${part}`;
  if (a.y - b.y === 1) return locale === 'ja' ? `去年の${season}の${part}` : `작년 ${season} ${part}`;
  return locale === 'ja' ? `${b.y}年の${season}` : `${b.y}년 ${season}`;
}

function englishWords(
  then: Date,
  now: Date,
  a: ReturnType<typeof zoned>,
  b: ReturnType<typeof zoned>,
  gap: number,
  partKey: Part,
  southern: boolean
): string {
  if (then.getTime() > now.getTime() + 60_000) return gap === 0 ? EN.today[partKey] : EN.tomorrow[partKey];
  if (gap <= 0) return now.getTime() - then.getTime() < 5 * 60_000 ? 'just now' : EN.today[partKey];
  if (gap === 1) return EN.yesterday[partKey];
  if (gap < 7) return EN.lately[partKey];
  const season = SEASON.en[seasonOf(b.m, southern)];
  const night = PART.en[partKey];
  if (a.y === b.y) return `${aOrAn(season)} ${season} ${night}`;
  if (a.y - b.y === 1) return `${aOrAn(season)} ${season} ${night} last year`;
  return `${season} ${b.y}`;
}

// 約四半刻 ── 「約」を付けて言う、見直しの余白のことば。
export function delayWords(min: number, locale: Locale): string {
  if (locale === 'en') {
    if (min <= 0) return 'right away';
    if (min <= 20) return 'about a quarter of an hour';
    if (min <= 45) return 'about half an hour';
    return 'about an hour';
  }
  if (min <= 0) return locale === 'ja' ? 'すぐ' : '곧';
  if (min <= 20) return locale === 'ja' ? '約四半刻' : '약 15분쯤';
  if (min <= 45) return locale === 'ja' ? '半刻ほど' : '30분쯤';
  return locale === 'ja' ? '一刻ほど' : '한 시간쯤';
}
