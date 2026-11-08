// SPDX-License-Identifier: AGPL-3.0-or-later
/* 部屋(/room)のデモ。データは、この画面の中だけ。どこにも送らない。 */
(() => {
  'use strict';

  // ---------- 小さな道具 ----------
  const $ = (s, el = document) => el.querySelector(s);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const reduced = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const later = (ms) => new Promise((r) => setTimeout(r, reduced() ? 0 : ms));
  // 時間は style.css の token から読む(指の画面とマウスの画面で、長さが違う)
  const ms = (name) => (reduced() ? 0 : parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name)) || 0);
  const EASE_OUT = 'cubic-bezier(0.16, 1, 0.3, 1)';
  const EASE_IN = 'cubic-bezier(0.3, 0, 0.8, 0.15)';
  const EASE_SOFT = 'cubic-bezier(0.45, 0, 0.25, 1)';
  const finger = () => window.matchMedia('(pointer: coarse)').matches;
  // 高さが変わるところは、跳ばずに伸び縮みさせる(前の高さ → 今の高さ)
  function morph(el, fromH, dur, easing) {
    if (!el || !dur || fromH == null) return;
    const to = el.offsetHeight;
    if (Math.abs(to - fromH) < 2) return;
    el.style.overflow = 'hidden';
    el.animate([{ height: fromH + 'px' }, { height: to + 'px' }], { duration: dur, easing })
      .finished.catch(() => {}).then(() => { el.style.overflow = ''; });
  }
  let serverWait = 220; // デモの操作で、サーバーの返事を遅くできる
  let uid = 100;
  const nid = () => 'm' + uid++;

  const WD = ['日', '月', '火', '水', '木', '金', '土'];
  function dayOf(offset) {
    const d = new Date();
    d.setDate(d.getDate() + offset);
    return d;
  }
  const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const jp = (d) => `${d.getMonth() + 1}月${d.getDate()}日(${WD[d.getDay()]})`;

  // ---------- まねのサーバー ----------
  const server = { room_welcomed_on: null };
  function log(line, res) {
    const ol = $('#apiLog');
    const li = document.createElement('li');
    li.innerHTML = esc(line) + (res ? `\n<span class="r">→ ${esc(res)}</span>` : '');
    ol.appendChild(li);
    ol.scrollTop = ol.scrollHeight;
  }
  const api = {
    async today(date) {
      await later(serverWait);
      const welcome = !server.room_welcomed_on || date > server.room_welcomed_on;
      log(`GET /api/i/room/today?date=${date}`, JSON.stringify({ welcome }));
      return { welcome };
    },
    async welcomed(date) {
      await later(120);
      if (!server.room_welcomed_on || date > server.room_welcomed_on) server.room_welcomed_on = date;
      log(`POST /api/i/room/today {"date":"${date}"}`, '204');
    },
    memo(method, body) {
      const { id, ...rest } = body || {};
      log(`${method} /api/i/room/memos${id ? '/' + id : ''} ${JSON.stringify(rest)}`, method === 'POST' ? '201' : '200');
    },
    layout(order, hidden) { log('sf.room.layout を保存(端末)、そっと同期', JSON.stringify({ order: order.slice(0, 4).concat(order.length > 4 ? ['…'] : []), hidden })); },
  };

  // ---------- はじめの状態 ----------
  const PEOPLE = () => [
    { id: 'p1', name: 'あおい', handle: '@aoi@sukhi.social', color: '#5b7f6e', kind: '返信', said: '昨日の写真、川沿いのところですか。今度歩いてみたいです。' },
    { id: 'p2', name: 'Mika', handle: '@mika@mastodon.example', color: '#8a6a52', kind: 'ダイレクト', said: '来週の集まり、ひなたさんも来られそう?無理なら大丈夫です。' },
    { id: 'p3', name: 'つむぎ', handle: '@tsumugi@misskey.example', color: '#6f6a8f', kind: '返信', said: 'その本、わたしも途中で止まってます。一緒に読み進めませんか。' },
  ];
  const REQUESTS = () => [
    { id: 'r1', name: 'ほしの', handle: '@hoshino@social.example', color: '#7d8a5a', note: '写真と散歩の話をしています。' },
  ];
  const MEMOS = () => [
    { id: nid(), note: 'Mika さんに、集まりのことを返す', when: 'today', state: 'open', ref: '@mika への返事' },
    { id: nid(), note: '週末に、写真の場所を教える', when: 'someday', state: 'open', ref: '@aoi の返信から' },
  ];
  const KEPT = () => [
    { note: '部屋の窓ぎわに、植物を置く', on: '11月2日' },
    { note: 'お知らせの書き方を、やさしく直す', on: '10月28日' },
  ];

  const TRACKS = [
    { id: 'morning-window', title: '朝の窓', artist: 'サンプルの作り手 A', bpm: 72, root: 57, prog: [[0, 4, 7, 11], [5, 9, 12, 16], [2, 5, 9, 12], [7, 11, 14, 17]] },
    { id: 'quiet-rain', title: '静かな雨', artist: 'サンプルの作り手 B', bpm: 66, root: 55, prog: [[0, 3, 7, 10], [5, 8, 12, 15], [-2, 2, 5, 9], [3, 7, 10, 14]] },
    { id: 'tea-steam', title: 'お茶の湯気', artist: 'サンプルの作り手 C', bpm: 78, root: 60, prog: [[0, 4, 7, 9], [-3, 0, 4, 7], [2, 5, 9, 12], [-5, -1, 2, 5]] },
  ];

  const WIDGETS = [
    { id: 'greeting', title: '挨拶', wide: true },
    { id: 'mailbox', title: '郵便箱', icon: 'mail', note: '人から届いたもの' },
    { id: 'notebook', title: '手帳' },
    { id: 'draft', title: '書きかけ' },
    { id: 'star', title: '星から' },
    { id: 'timeline', title: 'タイムライン' },
    { id: 'radio', title: 'ラジオ' },
    { id: 'elsewhere', title: 'ほかの部屋' },
    { id: 'window', title: '窓' },
    { id: 'kept', title: '果たした約束' },
  ];
  const byId = Object.fromEntries(WIDGETS.map((w) => [w.id, w]));

  let S;
  function fresh(keepServer) {
    if (!keepServer) server.room_welcomed_on = null;
    S = {
      view: 'room',
      dayOffset: 0,
      welcome: null, // true / false / null(読み込み中)
      period: S ? S.period : guessPeriod(),
      people: PEOPLE(),
      requests: REQUESTS(),
      reacted: [
        { name: 'あおい', color: '#5b7f6e' }, { name: 'Ren', color: '#9a7b4f' }, { name: 'ゆい', color: '#7a6f99' },
      ],
      announcement: { title: '星のお知らせ', body: '新しいラジオの棚ができました。名前を書けば使ってよい曲だけを、この星に置いています。', read: false },
      draft: '川沿いの道は、朝のほうが静かだった。光が水に',
      memos: MEMOS(),
      kept: KEPT(),
      replying: null,
      whisper: null,
      traces: [],
      tidyShown: false,
      editing: false,
      order: WIDGETS.map((w) => w.id),
      hidden: [],
      quiet: false,
      returned: false,
      memoWhen: 'today',
      radio: { shelf: 'star', playing: false, track: 0, ytConsent: false, ytPlaying: null, mine: [], mineHint: null },
      gogh: { quietToo: true },
    };
  }
  function guessPeriod() {
    const h = new Date().getHours();
    if (h >= 5 && h < 11) return 'morning';
    if (h >= 11 && h < 16) return 'day';
    if (h >= 16 && h < 19) return 'evening';
    return 'night';
  }

  // ---------- 音(星の棚のまね。中身は lofi.js) ----------
  const audio = {
    start(track) { return window.Lofi ? window.Lofi.start(track.id) : false; },
    stop() { if (window.Lofi) window.Lofi.stop(); },
  };

  function mediaSession(track) {
    if (!('mediaSession' in navigator)) return;
    try {
      navigator.mediaSession.metadata = track ? new MediaMetadata({ title: track.title, artist: track.artist, album: '星の棚(sukhi.social)' }) : null;
      navigator.mediaSession.setActionHandler('play', () => { if (!S.radio.playing) toggleStar(); });
      navigator.mediaSession.setActionHandler('pause', () => { if (S.radio.playing) toggleStar(); });
      navigator.mediaSession.setActionHandler('nexttrack', () => nextTrack());
    } catch (e) { /* 対応していない環境 */ }
  }

  function toggleStar() {
    const r = S.radio;
    if (r.playing) { audio.stop(); r.playing = false; mediaSession(null); }
    else {
      if (r.ytPlaying) foldYT(true);
      r.playing = audio.start(TRACKS[r.track]);
      if (!r.playing) say('この環境では、音を流せませんでした。', 'radio');
      mediaSession(TRACKS[r.track]);
    }
    render();
  }
  function nextTrack() {
    const r = S.radio;
    r.track = (r.track + 1) % TRACKS.length;
    if (r.playing) { audio.start(TRACKS[r.track]); mediaSession(TRACKS[r.track]); }
    render();
  }

  // ---------- YouTube の棚(まね) ----------
  const YT_PICKS = [
    { id: 'demo-official-1', title: 'おすすめ:公式チャンネルの lofi 配信(例)', by: '権利者の公式チャンネル' },
  ];
  function playYT(item) {
    const r = S.radio;
    if (r.playing) { audio.stop(); r.playing = false; mediaSession(null); }
    r.ytPlaying = item;
    $('#ytDock').hidden = false;
    $('#ytNow').textContent = '流れているつもり:' + item.title;
    log(`iframe https://www.youtube-nocookie.com/embed/${item.id}`, '(デモでは読み込まない)');
    render();
  }
  function foldYT(silent) {
    S.radio.ytPlaying = null;
    $('#ytDock').hidden = true;
    if (!silent) { say('窓を畳みました。音も止まります。', 'radio'); render(); }
  }
  function parseYT(url) {
    try {
      const u = new URL(url.trim());
      const host = u.hostname.replace(/^www\.|^m\./, '');
      if (host === 'youtu.be') return { id: u.pathname.slice(1), kind: '動画' };
      if (host === 'youtube.com' || host === 'music.youtube.com') {
        if (u.searchParams.get('list')) return { id: 'videoseries?list=' + u.searchParams.get('list'), kind: '再生リスト' };
        if (u.searchParams.get('v')) return { id: u.searchParams.get('v'), kind: '動画' };
        const m = u.pathname.match(/^\/(?:live|embed|shorts)\/([\w-]+)/);
        if (m) return { id: m[1], kind: '動画' };
      }
    } catch (e) { /* つながりではない */ }
    return null;
  }

  // ---------- ひとこと ----------
  // 部品についての一言は、その部品の中に出す(at = 部品の id)。at が無いものだけ、部屋の上に。
  function say(text, at = null) { S.whisper = { text, at }; announce(text); }
  // 読み上げは、描き直しに左右されない一つの場所から。
  function announce(text) {
    const live = $('#live'); if (!live) return;
    live.textContent = '';
    setTimeout(() => { live.textContent = text.replace(/<[^>]+>/g, ''); }, 30);
  }

  // ---------- 跡(押したところに残る一言) ----------
  // 消えたものの場所に、一行だけ残る。次に何か押すまで、そのまま。
  // undo は、本当に元どおりに戻せるときだけ付ける(送った返信や、迎えた人には付けない)。

  function leaveTrace(t) { S.traces.push(t); announce(t.text + (t.undo ? '(もどせます)' : '')); }
  function clearTraces() { S.traces = []; }
  const traceOf = (key) => S.traces.find((t) => t.key === key);
  // 並びの中に、跡を元の位置で差し込む
  function withTraces(list, arr) {
    const out = arr.map((item) => ({ item }));
    S.traces.filter((t) => t.list === list).sort((a, b) => a.at - b.at)
      .forEach((t) => out.splice(Math.min(t.at, out.length), 0, { trace: t }));
    return out;
  }
  const traceHtml = (t, tag = 'li') => `<${tag} class="trace" data-trace="${t.key}" tabindex="-1">
      <p>${t.text}</p>${t.undo ? `<button class="text-btn" data-act="undo" data-id="${t.key}">もどす</button>` : ''}
    </${tag}>`;

  // ---------- 描画 ----------
  const view = $('#view');

  function render() {
    document.body.dataset.period = S.period;
    document.body.classList.toggle('on-room', S.view === 'room');
    document.querySelectorAll('.nav-link[data-go]').forEach((b) => {
      const on = b.dataset.go === S.view || (S.view === 'kept' && b.dataset.go === 'room');
      if (on) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
    });
    $('#quietBanner').hidden = !S.quiet;
    if (S.view === 'room') renderRoom();
    else if (S.view === 'timeline') renderTimeline();
    else if (S.view === 'notifications') renderNotifications();
    else if (S.view === 'compose') renderCompose();
    else if (S.view === 'kept') renderKept();
  }

  const whisperHtml = () => `<div class="whisper"><p>${S.whisper.text}</p><button class="text-btn" data-act="whisper-x" aria-label="閉じる">閉じる</button></div>`;

  function tidyLevel() {
    const total = 4; // はじめの、返信とフォロー申請(数は画面に出さない)
    const left = S.people.length + S.requests.length;
    return Math.max(0, Math.min(1, 1 - left / total));
  }

  function renderRoom() {
    document.body.style.setProperty('--room-light', tidyLevel().toFixed(2));
    const d = dayOf(S.dayOffset);
    const tidy = S.people.length === 0 && S.requests.length === 0;
    const order = S.order.filter((id) => !S.hidden.includes(id));
    view.innerHTML = `
      <div class="room-head">
        <div>
          <h1>部屋</h1>
          <div class="room-date">${esc(jp(d))}</div>
        </div>
        <button class="btn quiet" data-act="edit" aria-pressed="${S.editing}">${S.editing ? '整え終わる' : '部屋を整える'}</button>
      </div>
      ${S.whisper && !S.whisper.at ? whisperHtml() : ''}
      ${tidy ? `<div class="tidy" role="status"><p>片づきました。部屋に残っても、タイムラインに出かけても、どちらでも。</p></div>` : ''}
      <div class="grid ${S.editing ? 'editing' : ''} ${twoCols() ? '' : 'one'}">
        ${columns(order)}
      </div>
      ${S.editing && S.hidden.length ? `
        <div class="hidden-shelf">
          <p>しまってある部品</p>
          <div class="chips">${S.hidden.map((id) => `<button class="btn" data-act="show" data-id="${id}">${esc(byId[id].title)}を出す</button>`).join('')}</div>
        </div>` : ''}
    `;
  }

  const WEIGHT = { notebook: 2.2, draft: 1, star: 1.3, timeline: 1.3, radio: 3, elsewhere: 2, window: 1, kept: 1 };
  const twoCols = () => window.matchMedia('(min-width: 761px)').matches;
  function columns(order) {
    const n = order.length;
    const html = (id) => widget(id, order.indexOf(id), n);
    const wide = order.filter((id) => byId[id].wide);
    const rest = order.filter((id) => !byId[id].wide);
    if (!twoCols()) return order.map(html).join('');
    // 並びの順を保ったまま、低いほうの列に置く(人が先、という順はそのまま)
    const cols = [[], []]; const h = [0, 0];
    for (const id of rest) {
      const weight = id === 'mailbox' ? Math.min(3, S.people.length) * 1.1 + S.requests.length * 1.1 + (S.reacted.length ? 0.9 : 0) + 0.6 : (WEIGHT[id] || 1);
      const c = h[0] <= h[1] ? 0 : 1; cols[c].push(id); h[c] += weight;
    }
    return wide.map(html).join('') + cols.map((c) => `<div class="col">${c.map(html).join('')}</div>`).join('');
  }

  function editbar(id) {
    if (id === 'greeting') return '';
    const vis = S.order.filter((x) => !S.hidden.includes(x) && x !== 'greeting');
    const i = vis.indexOf(id); const n = vis.length;
    return `<div class="editbar">
      <button class="text-btn" data-act="up" data-id="${id}" ${i === 0 ? 'disabled' : ''} aria-label="${esc(byId[id].title)}を上へ">上へ</button>
      <button class="text-btn" data-act="down" data-id="${id}" ${i === n - 1 ? 'disabled' : ''} aria-label="${esc(byId[id].title)}を下へ">下へ</button>
      <button class="text-btn" data-act="hide" data-id="${id}">しまう</button>
    </div>`;
  }

  function widget(id, i, n) {
    const w = byId[id];
    const body = BODIES[id]();
    return `<section class="w ${w.wide ? 'wide' : ''}" data-w="${id}" aria-labelledby="h-${id}">
      ${editbar(id, i, n)}
      ${id === 'greeting' ? `<h2 id="h-${id}" class="sr" hidden>${w.title}</h2>` : `<h2 id="h-${id}" class="${w.icon ? 'w-head' : ''}">${w.icon ? ICON[w.icon] : ''}<span>${esc(w.title)}</span>${w.note ? `<span class="w-note">${esc(w.note)}</span>` : ''}</h2>`}
      ${body}
      ${S.whisper && S.whisper.at === id ? whisperHtml().replace('class="whisper"', 'class="whisper in-w"') : ''}
    </section>`;
  }

  // 線のアイコン(web-next の nav-ico と同じ描き方)。意味は、いつも横の言葉が運ぶ。
  const ico = (d) => `<svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${d}</svg>`;
  const ICON = {
    mail: ico('<path d="M4 9.5 12 4l8 5.5V19H4Z" /><path d="M4 9.5 12 15l8-5.5" />'),
    reply: ico('<path d="M5 6h14v9H10l-4 3.5V15H5Z" />'),
    door: ico('<path d="M7 20V4.5h10V20" /><path d="M4.5 20h15" /><path d="M14 12.5h.01" />'),
    star: ico('<path d="m12 4.5 2.3 4.7 5.2.8-3.8 3.6.9 5.1-4.6-2.4-4.6 2.4.9-5.1-3.8-3.6 5.2-.8Z" />'),
  };

  const av = (p, cls = '') => `<span class="av ${cls}" style="background:${p.color}" aria-hidden="true">${esc(p.name.slice(0, 1))}</span>`;

  const HELLO = { morning: 'おはよう', day: 'こんにちは', evening: 'おつかれさま', night: 'こんばんは' };
  const WEATHER = { morning: 'いまは、静かです。', day: 'いまは、ほどよくにぎやかです。', evening: 'いまは、ゆっくりしています。', night: 'いまは、ほとんど眠っています。' };

  const BODIES = {
    greeting() {
      let hello, sub;
      // 待つあいだ:1.2秒までは何も出さない(すぐ消える「たずねています」は、ちらつくだけ)。
      // それを過ぎたら言葉で。10秒を過ぎたら、待たなくていいと添える。数字や棒は出さない。
      if (S.welcome === null) {
        if (!S.asking) { hello = ''; sub = ''; }
        else if (S.asking === 1) { hello = '…'; sub = '今日のことを、たずねています。'; }
        else { hello = '…'; sub = '少し、時間がかかっています。部屋は、このまま使えます。'; }
      }
      else if (S.returned) { hello = 'おかえりなさい。'; sub = '部屋は、そのままにしてあります。'; }
      else if (S.welcome) { hello = 'ようこそ、今日へ。'; sub = `${HELLO[S.period]}。星の天気:${WEATHER[S.period]}`; }
      else { hello = HELLO[S.period] + '。'; sub = `星の天気:${WEATHER[S.period]}`; }
      return `<div class="greet${S.welcome !== null && S.askedAt !== undefined ? ' arrived' : ''}">
        <div><p class="hello">${esc(hello)}</p><p class="sub">${esc(sub)}</p></div>
        <div class="windowpane" aria-hidden="true">${sky()}</div>
      </div>`;
    },
    notebook() {
      const open = S.memos.filter((m) => m.state === 'open' || traceOf('memo:' + m.id));
      const today = open.filter((m) => m.when === 'today');
      const someday = open.filter((m) => m.when !== 'today');
      const item = (m) => traceOf('memo:' + m.id) ? traceHtml(traceOf('memo:' + m.id), 'div') : `<div class="memo ${m.fresh ? 'fresh' : ''}" data-memo="${m.id}">
        <div class="text">${esc(m.note)}${m.ref ? `<span class="ref">${esc(m.ref)}</span>` : ''}</div>
        <div class="btns">
          <button class="text-btn" data-act="done" data-id="${m.id}">済ませる</button>
          <button class="text-btn" data-act="letgo" data-id="${m.id}">手放す</button>
        </div></div>`;
      return `<form class="memo-add" data-form="memo">
          <label class="sr" for="memoIn" hidden>手帳に書く</label>
          <input id="memoIn" type="text" maxlength="200" placeholder="自分で決めたことを、一行で" autocomplete="off">
          <button class="btn" type="submit">書く</button>
        </form>
        <div class="memo-when" role="radiogroup" aria-label="いつ">
          <label><input type="radio" name="when" value="today" ${S.memoWhen === 'today' ? 'checked' : ''}> 今日</label>
          <label><input type="radio" name="when" value="someday" ${S.memoWhen === 'someday' ? 'checked' : ''}> そのうち</label>
        </div>
        ${!open.length ? '<p class="calm">手帳は、いま空いています。</p>' : ''}
        ${today.length ? `<div class="memo-group">今日</div>${today.map(item).join('')}` : ''}
        ${someday.length ? `<div class="memo-group">そのうち</div>${someday.map(item).join('')}` : ''}`;
    },
    draft() {
      if (!S.draft) return `<p class="calm">書きかけは、ありません。</p>`;
      return `<p class="lead">「${esc(S.draft.length > 34 ? S.draft.slice(0, 34) + '…' : S.draft)}」</p>
        <div class="actions"><button class="btn" data-go="compose">続きを書く</button></div>`;
    },
    mailbox() {
      // 順番は固定:返信(人が言葉を待っている)→ フォロー申請(決めるのは、急がなくていい)→ 気に入った(読むだけ)。
      // 届いた時刻では並べ替えない。届いていない行は出さない。数は言わない。
      const rows = [];
      const replies = withTraces('people', S.people.slice(0, 3));
      const reqs = withTraces('requests', S.requests);
      if (replies.length) {
        const shown = replies;
        rows.push(`<section class="mb-row" aria-labelledby="mb-reply">
          <h3 id="mb-reply" class="mb-head">${ICON.reply}<span>返信が届いています</span></h3>
          ${`<ul class="cards">${shown.map(({ item: p, trace }) => trace ? traceHtml(trace) : `
        <li class="entry" data-card="${p.id}">
          <div class="who">${av(p)}
            <div>
              <div><span class="name">${esc(p.name)}</span> <span class="handle">${esc(p.handle)}</span></div>
              <div class="kind">${esc(p.kind)}</div>
              <p class="said">${esc(p.said)}</p>
            </div>
          </div>
          ${S.replying === p.id ? `
            <div class="reply">
              <label class="small muted" for="rp-${p.id}">${esc(p.name)} さんへ</label>
              <textarea id="rp-${p.id}" data-reply-text>${esc(p.name)}さん、</textarea>
              <div class="actions" style="margin-top:0">
                <button class="btn primary" data-act="send" data-id="${p.id}">返す</button>
                <button class="btn quiet" data-act="cancel-reply">やめる</button>
              </div>
            </div>` : `
            <div class="actions">
              <button class="btn" data-act="reply" data-id="${p.id}">返す</button>
              <button class="btn" data-act="to-notebook" data-id="${p.id}">手帳に入れる</button>
              <button class="btn quiet" data-act="set-down" data-id="${p.id}">置く</button>
            </div>`}
        </li>`).join('')}</ul>
        ${S.people.length > 3 ? '<p class="calm small" style="margin-top:.75rem">ほかにも、返信が届いています。</p>' : ''}`}
        </section>`);
      }
      if (reqs.length) {
        rows.push(`<section class="mb-row" aria-labelledby="mb-follow">
          <h3 id="mb-follow" class="mb-head">${ICON.door}<span>フォロー申請が届いています</span></h3>
          <p class="mb-sub">迎えるかどうかは、急がなくて大丈夫です。</p>
          ${`<ul class="cards">${reqs.map(({ item: p, trace }) => trace ? traceHtml(trace) : `
        <li class="entry" data-card="${p.id}">
          <div class="who">${av(p)}
            <div>
              <div><span class="name">${esc(p.name)}</span> <span class="handle">${esc(p.handle)}</span></div>
              <p class="said">${esc(p.note)}</p>
            </div>
          </div>
          <div class="actions">
            <button class="btn" data-act="welcome" data-id="${p.id}">迎える</button>
            <button class="btn quiet" data-act="not-now" data-id="${p.id}">今は迎えない</button>
            <button class="btn quiet" data-act="req-later" data-id="${p.id}">あとで(手帳へ)</button>
          </div>
        </li>`).join('')}</ul>`}
        </section>`);
      }
      if (S.reacted.length) {
        const names = S.reacted.slice(0, 2).map((r) => r.name + 'さん').join('、');
        rows.push(`<section class="mb-row" aria-labelledby="mb-liked">
          <h3 id="mb-liked" class="mb-head">${ICON.star}<span>投稿を気に入ってくれた人がいます</span></h3>
          <div class="rowline"><span class="faces">${S.reacted.map((r) => av(r)).join('')}</span>
            <p class="lead">${esc(names)}${S.reacted.length > 2 ? 'たち' : ''}から。返さなくて大丈夫です。</p></div>
          <div class="actions"><button class="btn" data-go="notifications">開いて読む</button><button class="btn quiet" data-act="read-reactions">読みました</button></div>
        </section>`);
      }
      const liked = traceOf('liked');
      if (!S.reacted.length && liked) rows.push(`<section class="mb-row">${traceHtml(liked, 'div')}</section>`);
      if (!rows.length) return `<p class="calm">郵便箱は、からっぽです。</p>`;
      return rows.join('');
    },
    star() {
      const a = S.announcement;
      if (a.read) return `<p class="calm">星からの知らせは、読みました。</p>`;
      return `<p class="lead"><b>${esc(a.title)}</b></p><p class="lead small" style="margin-top:.25rem">${esc(a.body)}</p>
        <div class="actions"><button class="btn" data-act="read-star">読んだ</button></div>`;
    },
    timeline() {
      return `<ul class="peek">
          <li><b>Ren</b> 駅前のパン屋、今日は早く閉まるみたい</li>
          <li><b>ゆい</b> 新しい刺繍の図案を描いています</li>
        </ul>
        <button class="door" data-go="timeline"><span>タイムラインへ</span><span aria-hidden="true">→</span></button>`;
    },
    radio() {
      const r = S.radio;
      const shelves = `<div class="shelves" role="group" aria-label="棚を選ぶ">
          <button data-act="shelf" data-shelf="star" aria-pressed="${r.shelf === 'star'}">星の棚</button>
          <button data-act="shelf" data-shelf="yt" aria-pressed="${r.shelf === 'yt'}">YouTube の棚</button>
        </div>`;
      if (r.shelf === 'star') {
        const t = TRACKS[r.track];
        return `${shelves}
          <div class="remote">
            <button class="playbtn" data-act="play" aria-label="${r.playing ? '止める' : '流す'}">${r.playing
              ? '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="3" y="2" width="3.5" height="12" rx="1" fill="currentColor"/><rect x="9.5" y="2" width="3.5" height="12" rx="1" fill="currentColor"/></svg>'
              : '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 2.5v11l9.5-5.5z" fill="currentColor"/></svg>'}</button>
            <div class="now">
              <div class="t">${esc(t.title)}${r.playing ? '<span class="bars" aria-hidden="true"><i></i><i></i><i></i><i></i></span>' : ''}</div>
              <div class="small muted">${esc(t.artist)}</div>
            </div>
            <button class="text-btn" data-act="next">次へ</button>
          </div>
          <label class="vol"><span class="small muted">音の大きさ</span><input type="range" min="0" max="100" step="1" value="${Math.round((window.Lofi ? window.Lofi.volume : 0.8) * 100)}" data-vol aria-label="音の大きさ"></label>
          <p class="credit">「${esc(t.title)}」${esc(t.artist)} / <a href="https://creativecommons.org/licenses/by/4.0/" target="_blank" rel="noopener">CC BY 4.0</a> / 元の頁 / 変更なし<br>デモの音は、その場で作ったものです。曲もクレジットも、まねです。</p>
          <ul class="tracklist" aria-label="星の棚の曲">
            ${TRACKS.map((x, i) => `<li><button data-act="pick" data-i="${i}" aria-current="${i === r.track}">${esc(x.title)} <span class="by">${esc(x.artist)}</span></button></li>`).join('')}
          </ul>
          <p class="hint">この星のサーバーから流れます。外にはつながりません。ほかの頁にいても、流れ続けます。</p>`;
      }
      // YouTube の棚
      if (!r.ytConsent) {
        return `${shelves}
          <div class="facade">
            <p>YouTube の棚では、もっと多くの曲や、自分の好きな一本を流せます。</p>
            <p class="small muted">押すと、YouTube(Google)につながります。あなたの IP は Google に届きます。押すまでは、何も読み込みません。</p>
            <button class="btn" data-act="yt-consent">YouTube につなぐ</button>
          </div>`;
      }
      const row = (it, mine) => `<li class="place"><span class="pn">${esc(it.title)}<br><span class="small muted">${esc(it.by)}</span></span>
          <button class="btn" data-act="yt-play" data-yt="${esc(it.id)}" data-mine="${mine ? 1 : 0}">${r.ytPlaying && r.ytPlaying.id === it.id ? '流れています' : '流す'}</button>
          ${mine ? `<button class="text-btn" data-act="yt-remove" data-yt="${esc(it.id)}">外す</button>` : ''}</li>`;
      return `${shelves}
        <ul class="places">${YT_PICKS.map((x) => row(x, false)).join('')}${r.mine.map((x) => row(x, true)).join('')}</ul>
        <form class="mine-add" data-form="mine">
          <label for="ytIn" hidden>YouTube のつながり</label>
          <input id="ytIn" type="url" placeholder="自分の一本:YouTube のつながりを貼る" autocomplete="off">
          <button class="btn" type="submit">棚に入れる</button>
        </form>
        <p class="hint ${r.mineHint && r.mineHint.warn ? 'warn' : ''}">${esc(r.mineHint ? r.mineHint.text : '権利者の公式チャンネルのものを選ぶと、安心です。')}</p>
        <p class="hint">流すと、隅に窓が開きます(見えたまま)。窓を畳むと、止まります。</p>`;
    },
    elsewhere() {
      return `<ul class="places">
          <li class="place"><span class="pn">gogh<br><span class="small muted">作業部屋と lofi</span></span>
            <button class="btn" data-act="gogh">開く</button></li>
          <li class="place"><span class="pn">作業用の部屋(Matrix)<br><span class="small muted">本人が置いた扉の例</span></span>
            <button class="btn" data-act="elsewhere-x">開く</button></li>
        </ul>
        <label class="check"><input type="checkbox" data-act="quiet-too" ${S.gogh.quietToo ? 'checked' : ''}> 開くとき「集中してきます」(sukhi をしばらく静かに)</label>`;
    },
    window() {
      return `<div class="goes">
          <button class="btn" data-act="go-map">星の路線図</button>
          <button class="btn" data-act="go-village">村(コミュニティ)── 連合ができたら</button>
        </div>`;
    },
    kept() {
      return `<p class="lead small">自分の言葉のまま、日付の順に並んでいます。</p>
        <div class="actions"><button class="btn" data-go="kept">果たした約束を見る</button></div>`;
    },
  };

  function sky() {
    const P = {
      morning: { a: '#fbe3c0', b: '#cfe2ea', sun: '#f6c76b', y: 46 },
      day: { a: '#bfdcec', b: '#e8f1f3', sun: '#fff1b8', y: 22 },
      evening: { a: '#f0b48a', b: '#9c8fb4', sun: '#f39a62', y: 60 },
      night: { a: '#1e2742', b: '#3a3f63', sun: '#efe9cf', y: 24 },
    }[S.period];
    const stars = S.period === 'night' ? [[18, 14], [44, 30], [70, 12], [112, 22], [138, 10], [96, 40]].map(([x, y]) => `<circle cx="${x}" cy="${y}" r="1.1" fill="#fff" opacity=".8"/>`).join('') : '';
    return `<svg viewBox="0 0 152 104" preserveAspectRatio="xMidYMid slice">
      <defs><linearGradient id="sk" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${P.b}"/><stop offset="1" stop-color="${P.a}"/></linearGradient></defs>
      <rect width="152" height="104" fill="url(#sk)"/>${stars}
      <circle cx="${S.period === 'night' ? 118 : 104}" cy="${P.y}" r="${S.period === 'night' ? 8 : 11}" fill="${P.sun}"/>
      ${S.period === 'night' ? '<circle cx="122" cy="21" r="7" fill="#2a3352"/>' : ''}
      <path d="M0 84 Q30 70 60 80 T120 76 T152 80 V104 H0Z" fill="${S.period === 'night' ? '#1a1f33' : '#9fb59a'}"/>
      <path d="M0 92 Q40 84 80 92 T152 90 V104 H0Z" fill="${S.period === 'night' ? '#141829' : '#86a284'}"/>
      <rect x="74" y="0" width="4" height="104" fill="#dcc7ae"/><rect x="0" y="50" width="152" height="4" fill="#dcc7ae"/>
    </svg>`;
  }

  // ---------- ほかの頁(まね) ----------
  function sub(title, inner) {
    view.innerHTML = `<div class="subpage">
      <button class="btn quiet back" data-go="room">← 部屋に戻る</button>
      <h1>${esc(title)}</h1>${inner}</div>`;
  }
  function renderTimeline() {
    sub('タイムライン', [
      ['Ren', '駅前のパン屋、今日は早く閉まるみたい。くるみのパンだけ買えた。'],
      ['ゆい', '新しい刺繍の図案を描いています。冬の鳥にしようかな。'],
      ['あおい', '川沿いの道、朝の光がきれいでした。'],
    ].map(([n, t]) => `<article class="post"><b>${esc(n)}</b><p style="margin:.25rem 0 0">${esc(t)}</p></article>`).join('') +
      '<p class="muted small">ここは、いまのタイムラインの頁です。部屋はナビの一番上から、いつでも戻れます。</p>');
  }
  function renderNotifications() {
    sub('通知', `<p class="muted">いまの通知の頁(あなたへ / 反応)。部屋からは、ここへの近道だけを置いています。</p>
      ${S.reacted.length ? `<article class="post">${esc(S.reacted.map((r) => r.name + 'さん').join('、'))}が、あなたの投稿を気に入りました。</article>
      <button class="btn" data-act="read-reactions">読みました</button>` : '<p class="muted">反応は、読みました。</p>'}`);
  }
  function renderCompose() {
    sub('書く', `<label class="small muted" for="draftIn">書きかけ(サーバーにそっと保存)</label>
      <textarea id="draftIn" style="min-height:9rem;margin-top:.25rem">${esc(S.draft)}</textarea>
      <div class="actions"><button class="btn primary" data-act="post">投稿する</button><button class="btn quiet" data-act="save-draft">書きかけのまま、部屋へ</button></div>`);
  }
  function renderKept() {
    sub('果たした約束', `<p class="muted small">自分で決めて、果たしたこと。数えません。</p>
      ${S.kept.map((k) => `<div class="kept-item"><div class="d">${esc(k.on)}</div><p>${esc(k.note)}</p></div>`).join('') || '<p class="muted">まだ、ここには何もありません。それでも大丈夫です。</p>'}`);
  }

  // ---------- 動き ----------
  document.addEventListener('input', (e) => {
    if (e.target.matches('[data-vol]') && window.Lofi) window.Lofi.setVolume(e.target.value / 100);
  });
  // 頁を移る:前の頁がすっと引いて(短く)、次の頁が入る(少し長く)。
  // 指の画面では、奥へ行くときは右から、部屋へ戻るときは左から(アプリの「進む・戻る」と同じ向き)。
  // マウスの画面では、横には動かさず、溶けるだけ。上へのスクロールは、見えないあいだに済ませる。
  let moving = 0;
  async function go(v) {
    const from = S.view;
    S.view = v; clearTraces();
    if (from === v || reduced()) {
      render();
      window.scrollTo({ top: 0, behavior: 'auto' });
      $('#main').focus({ preventScroll: true });
      return;
    }
    const mine = ++moving;
    view.getAnimations().forEach((a) => a.cancel());
    await view.animate([{ opacity: 1 }, { opacity: 0 }], { duration: ms('--t-page-out'), easing: EASE_IN, fill: 'forwards' }).finished.catch(() => {});
    if (mine !== moving) return;
    render();
    window.scrollTo({ top: 0, behavior: 'auto' });
    view.getAnimations().forEach((a) => a.cancel());
    const dx = finger() ? (v === 'room' ? -16 : 16) : 0;
    const dy = finger() ? 0 : 4;
    view.animate([{ opacity: 0, transform: `translate(${dx}px, ${dy}px)` }, { opacity: 1, transform: 'none' }], { duration: ms('--t-page-in'), easing: EASE_SOFT });
    $('#main').focus({ preventScroll: true });
  }

  // キーボードが出ても、書いている欄と「返す」が隠れないように(iPhone は画面が縮まないので、見える範囲を見て寄せる)
  // 動かすのは、隠れているときだけ。真ん中に寄せ直したりはしない(画面が勝手に跳ばないように)。
  // マウスの画面:欄が開ききってから、はみ出ていれば少しだけ。
  // 指の画面:キーボードが上がりきるのを待ってから(見える範囲が縮むのを見て)、隠れた分だけ。
  function keepInView(el) {
    const box = el.closest('.reply') || el;
    const nudge = () => {
      if (document.activeElement !== el) return;
      const vv = window.visualViewport;
      const top = vv ? vv.offsetTop : 0;
      const bottom = top + (vv ? vv.height : window.innerHeight);
      const r = box.getBoundingClientRect();
      const pad = 12;
      let dy = 0;
      if (r.bottom > bottom - pad) dy = r.bottom - (bottom - pad);
      if (r.top - dy < top + pad) dy = r.top - (top + pad);
      if (Math.abs(dy) > 1) window.scrollBy({ top: dy, behavior: reduced() ? 'auto' : 'smooth' });
    };
    const grown = ms('--t-ack') + 50; // 欄が広がりきってから測る
    if (!finger() || !window.visualViewport) { setTimeout(nudge, grown); return; }
    let waited = null;
    const t0 = performance.now();
    const onResize = () => { clearTimeout(waited); waited = setTimeout(nudge, Math.max(60, grown - (performance.now() - t0))); };
    window.visualViewport.addEventListener('resize', onResize);
    el.addEventListener('blur', () => window.visualViewport.removeEventListener('resize', onResize), { once: true });
    setTimeout(nudge, grown); // キーボードの付いた端末(外付けなど)で、縮まないとき
  }

  // 「うん、わかった。」(押したものが下がる)→ ひと呼吸 →「君のことを教えて」(跡が現れる)。
  // 待つあいだも、ほかのものは押せる。どこも止めない。
  async function fold(selector, then) {
    const el = view.querySelector(selector);
    if (el && el.classList.contains('leaving')) return; // 二度押し
    const h0 = el ? el.offsetHeight : null;
    if (el) { el.classList.add('leaving'); await later(ms('--t-ack') + ms('--t-breath')); }
    const key = el ? (el.dataset.card ? 'card:' + el.dataset.card : 'memo:' + el.dataset.memo) : null;
    const wasHere = !document.activeElement || document.activeElement === document.body || (el && el.contains(document.activeElement));
    then();
    render();
    const tr = key && view.querySelector(`[data-trace="${key}"]`);
    morph(tr, h0, ms('--t-say'), EASE_SOFT); // 空いた場所は、跡の高さまで、ゆっくり縮む
    if (wasHere) focusTrace(tr);
  }
  // 押したボタンは消えたので、手元の跡に焦点を移す(画面は動かさない)
  function focusTrace(t) { const el = t || view.querySelector('.trace'); if (el) el.focus({ preventScroll: true }); }
  function focusIn(sel) { const el = view.querySelector(sel); if (el) { el.setAttribute('tabindex', '-1'); el.focus({ preventScroll: true }); } }

  function addMemo(note, when, ref) {
    const m = { id: nid(), note, when, state: 'open', ref, fresh: true };
    S.memos.push(m);
    api.memo('POST', { note, when, ref: ref || undefined });
    setTimeout(() => { m.fresh = false; }, 600);
  }

  function todayNote() {
    const d = dayOf(S.dayOffset);
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }

  view.addEventListener('click', async (e) => {
    const t = e.target.closest('[data-act],[data-go]');
    if (!t) return;
    if (t.dataset.go) { clearTraces(); go(t.dataset.go); return; }
    const id = t.dataset.id; const act = t.dataset.act;
    if (act !== 'undo' && act !== 'whisper-x') { clearTraces(); if (S.whisper && S.whisper.at) S.whisper = null; }
    const person = S.people.find((p) => p.id === id);
    const req = S.requests.find((p) => p.id === id);

    switch (act) {
      case 'whisper-x': S.whisper = null; render(); break;
      case 'edit':
        S.editing = !S.editing;
        if (!S.editing) api.layout(S.order, S.hidden);
        render(); break;
      case 'up': case 'down': {
        const vis = S.order.filter((x) => !S.hidden.includes(x) && x !== 'greeting');
        const i = vis.indexOf(id); const j = act === 'up' ? i - 1 : i + 1;
        if (j < 0 || j >= vis.length) break;
        const a = S.order.indexOf(vis[i]); const b = S.order.indexOf(vis[j]);
        [S.order[a], S.order[b]] = [S.order[b], S.order[a]];
        render();
        const again = view.querySelector(`[data-act="${act}"][data-id="${id}"]`);
        if (again && !again.disabled) again.focus();
        break;
      }
      case 'hide': S.hidden.push(id); render(); break;
      case 'show': S.hidden = S.hidden.filter((x) => x !== id); render(); break;

      // 返す:ボタンの列が、その場で書く欄に育つ。画面は入れ替えない。
      // 焦点は押したその手のうちに移す(iPhone は、そうしないとキーボードを出さない)。
      case 'reply': {
        const card = view.querySelector(`[data-card="${id}"]`); const h0 = card ? card.offsetHeight : null;
        S.replying = id; render();
        const c2 = view.querySelector(`[data-card="${id}"]`);
        const ta = view.querySelector('[data-reply-text]');
        if (ta) { ta.focus({ preventScroll: true }); ta.setSelectionRange(ta.value.length, ta.value.length); }
        const d = ms('--t-ack'); // 文字はすぐ打てる。欄が広がるのは「うん、わかった」の長さで
        morph(c2, h0, d, EASE_SOFT);
        const box = c2 && c2.querySelector('.reply');
        if (box && d) box.animate([{ opacity: 0, transform: 'translateY(-4px)' }, { opacity: 1, transform: 'none' }], { duration: d, easing: EASE_SOFT });
        if (ta) keepInView(ta);
        break; }
      // やめる:欄はすっと畳む(開くより短く)。焦点は、もとの「返す」へ。
      case 'cancel-reply': {
        const rid = S.replying;
        const card = view.querySelector(`[data-card="${rid}"]`);
        const box = card && card.querySelector('.reply');
        const d = ms('--t-ack');
        if (box && d) await box.animate([{ opacity: 1 }, { opacity: 0, transform: 'translateY(-4px)' }], { duration: d * 0.6, easing: EASE_SOFT, fill: 'forwards' }).finished.catch(() => {});
        const h0 = card ? card.offsetHeight : null;
        S.replying = null; render();
        const c2 = view.querySelector(`[data-card="${rid}"]`);
        morph(c2, h0, d * 0.4, EASE_SOFT);
        const back = c2 && c2.querySelector('[data-act="reply"]'); if (back) back.focus({ preventScroll: true });
        break; }
      case 'send': {
        const at = S.people.indexOf(person);
        S.replying = null;
        await fold(`[data-card="${id}"]`, () => { S.people = S.people.filter((p) => p.id !== id); leaveTrace({ key: 'card:' + id, list: 'people', at, text: `${esc(person.name)}さんに、返しました。` }); });
        break; }
      case 'to-notebook': {
        const at = S.people.indexOf(person);
        addMemo(`${person.name}さんに返す`, 'today', `${person.handle} から`);
        await fold(`[data-card="${id}"]`, () => { S.people = S.people.filter((p) => p.id !== id); leaveTrace({ key: 'card:' + id, list: 'people', at, text: `手帳に入れました。「${esc(person.name)}さんに返す」` }); });
        break; }
      case 'set-down': {
        const at = S.people.indexOf(person);
        await fold(`[data-card="${id}"]`, () => { S.people = S.people.filter((p) => p.id !== id); leaveTrace({ key: 'card:' + id, list: 'people', at, item: person, undo: true, text: '置きました。通知の頁にも、残っています。' }); });
        break; }

      case 'welcome': {
        const at = S.requests.indexOf(req);
        await fold(`[data-card="${id}"]`, () => { S.requests = S.requests.filter((p) => p.id !== id); leaveTrace({ key: 'card:' + id, list: 'requests', at, text: `${esc(req.name)}さんを、迎えました。` }); });
        break; }
      case 'not-now': {
        const at = S.requests.indexOf(req);
        await fold(`[data-card="${id}"]`, () => { S.requests = S.requests.filter((p) => p.id !== id); leaveTrace({ key: 'card:' + id, list: 'requests', at, item: req, undo: true, text: '今は、迎えないことにしました。相手には、何も知らせません。' }); });
        break; }
      case 'req-later': {
        const at = S.requests.indexOf(req);
        addMemo(`${req.name}さんを迎えるか、考える`, 'someday', `${req.handle} のフォロー申請`);
        await fold(`[data-card="${id}"]`, () => { S.requests = S.requests.filter((p) => p.id !== id); leaveTrace({ key: 'card:' + id, list: 'requests', at, text: '手帳に入れました。申請は、そのまま待っていてくれます。' }); });
        break; }

      case 'done': {
        const m = S.memos.find((x) => x.id === id);
        api.memo('PATCH', { id, done: true });
        await fold(`[data-memo="${id}"]`, () => { m.state = 'kept'; S.kept.unshift({ note: m.note, on: todayNote() }); leaveTrace({ key: 'memo:' + id, text: `「${esc(m.note)}」── 果たしました。` }); });
        break;
      }
      case 'letgo': {
        const m = S.memos.find((x) => x.id === id);
        api.memo('PATCH', { id, let_go: true });
        await fold(`[data-memo="${id}"]`, () => { m.state = 'letgo'; leaveTrace({ key: 'memo:' + id, memo: m, undo: true, text: '手放しました。それも、ひとつの決め方です。' }); });
        break;
      }

      case 'read-star': S.announcement.read = true; announce('星からの知らせを、読みました。'); render(); focusIn('[data-w="star"]'); break;
      case 'read-reactions': S.reacted = []; if (S.view === 'room') leaveTrace({ key: 'liked', text: '読みました。' }); render(); focusTrace(); break;

      case 'undo': {
        const tr = traceOf(id); if (!tr) break;
        S.traces = S.traces.filter((x) => x !== tr);
        if (tr.memo) { tr.memo.state = 'open'; api.memo('PATCH', { id: tr.memo.id, let_go: false }); }
        else if (tr.list === 'people') S.people.splice(Math.min(tr.at, S.people.length), 0, tr.item);
        else if (tr.list === 'requests') S.requests.splice(Math.min(tr.at, S.requests.length), 0, tr.item);
        announce('もどしました。');
        render();
        const back = tr.memo ? `[data-memo="${tr.memo.id}"]` : `[data-card="${tr.item.id}"]`;
        const again = view.querySelector(back);
        if (again && ms('--t-say')) again.animate([{ opacity: 0 }, { opacity: 1 }], { duration: ms('--t-say'), easing: EASE_SOFT });
        const first = view.querySelector(`${back} button`); if (first) first.focus({ preventScroll: true });
        break;
      }

      case 'shelf': S.radio.shelf = t.dataset.shelf; render(); break;
      case 'play': toggleStar(); break;
      case 'next': nextTrack(); break;
      case 'pick': {
        S.radio.track = +t.dataset.i;
        if (S.radio.playing) { audio.start(TRACKS[S.radio.track]); mediaSession(TRACKS[S.radio.track]); render(); }
        else toggleStar();
        break;
      }
      case 'yt-consent': S.radio.ytConsent = true; log('(同意)YouTube の棚を開く', 'この端末に記録'); render(); break;
      case 'yt-play': {
        const list = t.dataset.mine === '1' ? S.radio.mine : YT_PICKS;
        const it = list.find((x) => x.id === t.dataset.yt);
        if (S.radio.ytPlaying && S.radio.ytPlaying.id === it.id) break;
        playYT(it); break;
      }
      case 'yt-remove':
        S.radio.mine = S.radio.mine.filter((x) => x.id !== t.dataset.yt);
        if (S.radio.ytPlaying && S.radio.ytPlaying.id === t.dataset.yt) foldYT(true);
        render(); break;

      case 'gogh':
        if (S.gogh.quietToo) { S.quiet = true; say('集中してきます。sukhi は、しばらく静かにしています。', 'elsewhere'); }
        else say('gogh を開きます(デモでは、ここで止めています)。', 'elsewhere');
        log('open steam://run/3213850(パソコン)/ https://gogh.gg/(ほか)', 'デモでは開かない');
        render(); break;
      case 'elsewhere-x': say('本人が置いた扉です(デモでは開きません)。', 'elsewhere'); render(); break;
      case 'go-map': say('星の路線図(/map)へ。デモでは、ここまでです。', 'elsewhere'); render(); break;
      case 'go-village': say('村は、Group の連合ができてからです。いまは、扉だけ。', 'elsewhere'); render(); break;

      case 'post': S.draft = ''; say('投稿しました。'); go('room'); break;
      case 'save-draft': { const v = $('#draftIn').value; S.draft = v; log('PUT /api/i/notes/drafts', '200'); go('room'); break; }
    }
  });

  view.addEventListener('change', (e) => {
    const t = e.target;
    if (t.name === 'when') S.memoWhen = t.value;
    if (t.dataset.act === 'quiet-too') S.gogh.quietToo = t.checked;
  });

  view.addEventListener('submit', (e) => {
    e.preventDefault();
    const f = e.target;
    if (f.dataset.form === 'memo') {
      const v = $('#memoIn').value.trim();
      if (!v) return;
      addMemo(v, S.memoWhen, null);
      render();
      $('#memoIn').focus();
    }
    if (f.dataset.form === 'mine') {
      const v = $('#ytIn').value;
      const p = parseYT(v);
      if (!p || !p.id) { S.radio.mineHint = { text: 'YouTube のつながりとして、読めませんでした。', warn: true }; render(); return; }
      if (!S.radio.mine.some((x) => x.id === p.id)) S.radio.mine.push({ id: p.id, title: `自分の一本(${p.kind})`, by: v.trim().replace(/^https?:\/\//, '').slice(0, 42) });
      S.radio.mineHint = { text: '自分の棚に入れました。あなたの口座にだけ置かれ、連合には出ません。' };
      log('POST /api/i/room/radio/mine', '201(本人だけ)');
      render();
    }
  });

  // 上のナビ
  document.querySelectorAll('.app-nav, .nav-bottom').forEach((n) => n.addEventListener('click', (e) => {
    const b = e.target.closest('[data-go]');
    if (b) { e.preventDefault(); go(b.dataset.go); }
  }));

  $('#quietBack').addEventListener('click', () => {
    S.quiet = false; S.returned = true; S.whisper = null; go('room');
  });
  $('#ytFold').addEventListener('click', () => foldYT(false));

  // デモの操作
  $('#nextDay').addEventListener('click', async () => {
    S.dayOffset += 1;
    S.returned = false;
    S.people = PEOPLE().slice(0, 2).map((p, i) => ({ ...p, id: p.id + 'd' + S.dayOffset, said: i === 0 ? '今朝も、川の写真を見ました。ありがとう。' : p.said }));
    S.requests = [];
    S.announcement.read = true;
    S.whisper = null;
    go('room');
    await enterRoom();
  });
  $('#reopen').addEventListener('click', async () => { S.returned = false; go('room'); await enterRoom(); });
  $('#resetAll').addEventListener('click', async () => {
    audio.stop(); foldYT(true);
    $('#apiLog').innerHTML = '';
    fresh(false);
    syncPeriodRadios();
    go('room');
    await enterRoom();
  });
  document.querySelectorAll('input[name="period"]').forEach((r) => r.addEventListener('change', () => { S.period = r.value; render(); }));
  function syncPeriodRadios() {
    document.querySelectorAll('input[name="period"]').forEach((r) => { r.checked = r.value === S.period; });
  }

  // 挨拶だけを描き直す(ほかの所で書いている途中のものを、こわさない)
  function paintGreeting() {
    const g = view.querySelector('.greet'); if (!g) return;
    g.outerHTML = BODIES.greeting();
  }
  async function enterRoom() {
    S.welcome = null; S.asking = 0; S.askedAt = 0; render();
    const date = iso(dayOf(S.dayOffset));
    let shownAt = 0;
    // 「うん、わかった。」の長さ(0.9秒+ひと呼吸)までは、黙って待つ
    const t1 = setTimeout(() => { S.asking = 1; shownAt = performance.now(); paintGreeting(); }, 1200);
    const t2 = setTimeout(() => { S.asking = 2; paintGreeting(); announce('少し、時間がかかっています。部屋は、このまま使えます。'); }, 10000);
    const { welcome } = await api.today(date);
    clearTimeout(t1); clearTimeout(t2);
    // 一度出した「たずねています」は、すぐには消さない(出てすぐ消えると、ちらつく)
    if (shownAt) await later(Math.max(0, shownAt + 900 - performance.now()));
    S.welcome = welcome; S.asking = 0;
    paintGreeting();
    S.askedAt = undefined;
    if (welcome) await api.welcomed(date);
  }

  // iPhone の Safari は、タッチの受け口がないと :active(押した色)を付けない
  document.addEventListener('touchstart', () => {}, { passive: true });
  // 指で素早く押すと、色が見える前に離れてしまう。押した色は、最低 100ms は残す(0.1秒の目安)。
  const PRESSABLE = '.btn, .text-btn, .shelves button, .tracklist button, .door';
  document.addEventListener('pointerdown', (e) => {
    if (e.pointerType !== 'touch') return;
    const b = e.target.closest(PRESSABLE); if (!b) return;
    b.classList.add('pressed');
    const t0 = performance.now();
    const up = () => setTimeout(() => b.classList.remove('pressed'), Math.max(0, 100 - (performance.now() - t0)));
    document.addEventListener('pointerup', up, { once: true });
    document.addEventListener('pointercancel', up, { once: true });
  }, { passive: true });
  document.querySelectorAll('input[name="wait"]').forEach((r) => r.addEventListener('change', () => { serverWait = +r.value; }));

  window.matchMedia('(min-width: 761px)').addEventListener('change', () => render());
  // はじめ
  fresh(false);
  syncPeriodRadios();
  render();
  log('GET /(ログインしている)', 'いつも /room へ');
  enterRoom();
})();
