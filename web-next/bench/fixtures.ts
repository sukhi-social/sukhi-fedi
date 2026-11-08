// SPDX-License-Identifier: AGPL-3.0-or-later
// Fixed inputs for the benchmarks: a timeline as the gateway would hand it
// over, and the MFM / HTML a remote note might carry. Everything is built
// from constants, so each run measures the same work.

import type { Ctx } from '../server/http.ts';
import { makeT, type Locale } from '../server/i18n.ts';
import type { Account, Emoji, Status } from '../server/types.ts';

export const NOW = new Date('2026-10-29T05:00:00Z');

export const EMOJIS: Emoji[] = Array.from({ length: 40 }, (_, i) => ({
  shortcode: `blob${i}`,
  url: `https://remote.example/emoji/blob${i}.png`,
  static_url: `https://remote.example/emoji/blob${i}.png`,
  visible_in_picker: true
})) as Emoji[];

export const MFM_SOURCE = [
  '**今日の昼下がり**、$[spin $[jelly ゆっくり]] 歩いてきました :blob3: 🌸',
  '> 引用の一行目 <b>太字</b>',
  '> 二行目 `code` と ~~消し~~',
  '<center>まんなか <small>ちいさく</small></center>',
  '```js',
  'const a = 1 < 2 && "x";',
  '```',
  '@alice@remote.example と @bob に、#散歩 #sukhi の [リンク](https://example.com/a?b=1) と https://example.org/path',
  '*斜め* と _下線風_ と __強め__ と <i>it</i> <s>strike</s> :blob7: :blob12: 😀👍🏽'
].join('\n');

export const LONG_MFM = Array.from({ length: 20 }, () => MFM_SOURCE).join('\n\n');

export const CONTENT_HTML =
  '<p>こんにちは、<span class="h-card"><a href="https://remote.example/@alice" class="u-url mention">@<span>alice</span></a></span> さん。' +
  '今日は :blob1: と :blob2: を連れて、川べりを歩きました 🌿🚶‍♀️。' +
  '<a href="https://remote.example/tags/散歩" class="mention hashtag" rel="tag">#<span>散歩</span></a></p>' +
  '<p>夕方の光がきれいで、すこし長く立ち止まってしまいました。:blob5: 🌇</p>';

export const JA_TEXT =
  '今日は朝からゆっくりと歩いて、川べりの道で、すこし長く立ち止まってしまいました。夕方の光がきれいで、帰り道はいつもより遠回りをしました。';

function account(i: number): Account {
  return {
    id: `acc${i % 7}`,
    username: `user${i % 7}`,
    acct: i % 2 ? `user${i % 7}@remote.example` : `user${i % 7}`,
    display_name: `ひと ${i % 7} :blob${i % 40}:`,
    avatar: `https://remote.example/avatars/${i % 7}.png`,
    avatar_static: `https://remote.example/avatars/${i % 7}.png`,
    note: '',
    url: `https://remote.example/@user${i % 7}`,
    emojis: EMOJIS.slice(0, 10),
    fields: [],
    bot: false,
    locked: false
  } as unknown as Account;
}

function status(i: number): Status {
  return {
    id: `${100000 - i}`,
    created_at: new Date(NOW.getTime() - i * 7 * 60 * 1000).toISOString(),
    account: account(i),
    content: CONTENT_HTML,
    spoiler_text: '',
    sensitive: false,
    visibility: 'public',
    url: `https://remote.example/@user${i % 7}/${100000 - i}`,
    in_reply_to_id: null,
    in_reply_to_account_id: null,
    reblog: null,
    media_attachments:
      i % 3 === 0
        ? [{ id: `m${i}`, type: 'image', url: `https://remote.example/m/${i}.jpg`, preview_url: `https://remote.example/m/${i}s.jpg`, description: '川べり' }]
        : [],
    mentions: [],
    tags: [],
    emojis: EMOJIS.slice(0, 10),
    reactions: i % 4 === 0 ? [{ name: '👍', count: 2, me: false }, { name: ':blob1:', count: 1, me: true, url: EMOJIS[1].url }] : [],
    favourited: i % 5 === 0,
    reblogged: false,
    bookmarked: false,
    poll: null
  } as unknown as Status;
}

export const TIMELINE: Status[] = Array.from({ length: 40 }, (_, i) => status(i));

export const ME: Account = account(1);

export function makeCtx(locale: Locale = 'ja'): Ctx {
  return {
    locale,
    tz: 'Asia/Tokyo',
    t: makeT(locale),
    url: new URL('https://sukhi.example/home'),
    params: {},
    method: 'GET',
    isUp: false,
    cookies: []
  } as unknown as Ctx;
}
