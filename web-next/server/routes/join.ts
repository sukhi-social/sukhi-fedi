// SPDX-License-Identifier: AGPL-3.0-or-later
// 入会の申し込み(docs/JOIN.md)。入るための合言葉(招待コード)のかわりに、
// 三つの質問に、書きたいところだけ書いて、連絡をくれる。
//
//   /join              書く(三つの質問とメールアドレス)
//     └ POST /join     → 関所(/check)→ gateway に預ける → /join/asked
//   /join/asked        「受付のメールはもらいましたか？」 はい → 編集のリンクがメールで届く / いいえ → /join/email
//   /join/email        アドレスを見直して、受付のメールを送り直す
//   /join/done         ありがとう。いつ確認するか
//   /join/edit/:key    メールのリンクから、書き直す
//
// 鍵は二つ。claim は、申し込んだこのブラウザ(session)だけが持つ ── 「はい」と言えるのは、ここから。
// key は、「はい」のあとにメールで届く編集のリンク。メールのアドレスを打ち間違えても、
// 書いた中身が他の人に届かないための順番(受付のメールには、受付番号だけ)。
// 送った人の回数制限は gateway が持つ(15 分に 10 回)── ここでは数えない。

import { gw, gwJson, GatewayError } from '../gateway.ts';
import { html, raw, type SafeHtml } from '../html.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import { saveSession, type JoinDraft } from '../session.ts';
import { layout } from '../views/layout.ts';
import { maybeMe } from './shared.ts';
import type { TranslationKey } from '../i18n.ts';

type Info = { greeter: string | null; weekday: number; days_after: number; check_on: string };
type Words = { receipt: string; call_name: string | null; found: string | null; hope: string | null; check_on: string };

// ── 小さな道具 ───────────────────────────────────────────────────

// 管理する人の名前と、確認する日。取れなくても、頁は開く(名前なしの言い方になる)。
async function info(ctx: Ctx): Promise<Info | null> {
  try {
    return await gwJson<Info>(ctx, 'GET', '/api/v1/join/info', { auth: false });
  } catch (e) {
    if (e instanceof GatewayError || e instanceof TypeError) return null;
    throw e;
  }
}

function daysText(ctx: Ctx, n: number): string {
  return n === 1 ? ctx.t('join.daysAfterOne') : ctx.t('join.daysAfter', { n });
}

// 「くろが確認するのは、木曜日(3日後)です。」 名前がまだ決まっていないときは、名前なしで。
function whenSentence(ctx: Ctx, greeter: string | null, weekday: number, daysAfter: number): string {
  const day = ctx.t(`join.wd${weekday}` as TranslationKey);
  const after = daysText(ctx, daysAfter);
  return greeter
    ? ctx.t('join.when', { who: greeter, day, after })
    : ctx.t('join.whenAnon', { day, after });
}

// 辞書の一文に、リンクだけ差し込む(語順・助詞は、言語ごとに一文の中で完結する)。
function withLink(text: string, link: SafeHtml): SafeHtml {
  return raw(text.replace('{link}', link.value));
}

const draftOf = (form: FormData): JoinDraft => {
  const get = (k: string) => String(form.get(k) ?? '');
  return { email: get('email').trim(), call_name: get('call_name'), found: get('found'), hope: get('hope') };
};

// gateway の「だめ」を、画面のことばにする。メールのアドレスは、直せば進めるので、別にして伝える。
function failure(ctx: Ctx, e: unknown): { error: string; status: number } {
  const t = ctx.t;
  if (e instanceof GatewayError) {
    if (e.status === 422) {
      const d = e.details ?? {};
      if ('email' in d) return { error: t('join.errEmail'), status: 422 };
      return { error: t('join.errTooLong'), status: 422 };
    }
    if (e.status === 429) return { error: t('join.rateLimited'), status: 429 };
  }
  if (e instanceof GatewayError || e instanceof TypeError) return { error: t('join.failed'), status: 502 };
  throw e;
}

// ── 頁 ───────────────────────────────────────────────────────────

async function frame(ctx: Ctx, title: string, body: SafeHtml, status = 200): Promise<Reply> {
  const me = await maybeMe(ctx);
  return ok(layout(ctx, { title, me, entrance: !me, legal: !me, body: html`<div class="measure stack join">${body}</div>` }), status);
}

type FormView = {
  draft?: Partial<JoinDraft>;
  error?: string;
  // 編集のリンクから来たとき。アドレスは動かさないので、欄を出さない。
  editKey?: string;
};

async function formPage(ctx: Ctx, v: FormView = {}, status = 200): Promise<Reply> {
  const t = ctx.t;
  const i = await info(ctx);
  const d = v.draft ?? {};
  const editing = v.editKey !== undefined;
  const who = i?.greeter ?? null;
  const tagline = who ? t('join.tagline', { who }) : t('join.taglineAnon');
  const termsLink = html`<a href="/terms">${t('join.termsLink')}</a>`;
  const body = html`<section class="hero">
      <h1>${t('join.title')}</h1>
      <p class="tagline">${tagline}</p>
    </section>
    ${editing ? html`<p class="notice" role="status">${t('join.editing')}</p>` : ''}
    ${v.error ? html`<p class="error" role="alert">${v.error}</p>` : ''}
    <form class="form stack" method="post" action="${editing ? `/join/edit/${encodeURIComponent(v.editKey!)}` : '/join'}">
      <p class="prose-small">${t('join.hint')}</p>
      <label class="stack-tight">
        <span>${t('join.q1')}</span>
        <input type="text" name="call_name" maxlength="40" autocomplete="off" value="${d.call_name ?? ''}" />
        <span class="help">${t('join.q1Help')}</span>
      </label>
      <label class="stack-tight">
        <span>${t('join.q2')}</span>
        <textarea name="found" rows="3" maxlength="1000">${d.found ?? ''}</textarea>
        <span class="help">${t('join.q2Help')}</span>
      </label>
      <label class="stack-tight">
        <span>${t('join.q3')}</span>
        <textarea name="hope" rows="4" maxlength="2000">${d.hope ?? ''}</textarea>
      </label>
      ${editing
        ? ''
        : html`<label class="stack-tight">
            <span>${t('join.email')}</span>
            <input type="email" name="email" value="${d.email ?? ''}" autocomplete="email" autocapitalize="none" spellcheck="false" maxlength="254" required />
            <span class="help">${t('join.emailHelp')}</span>
          </label>`}
      <button type="submit" class="btn primary px-6 py-2">${editing ? t('join.resend') : t('join.send')}</button>
    </form>
    ${!editing && i
      ? html`<p class="prose-small after-form">
          ${whenSentence(ctx, i.greeter, i.weekday, i.days_after)} ${t('join.reply')}
          ${withLink(t('join.terms'), termsLink)}
        </p>`
      : ''}
    ${editing ? '' : html`<p class="prose-small"><a href="/">${t('join.back')}</a></p>`}`;
  return frame(ctx, t('join.title'), body, status);
}

function askedPage(ctx: Ctx, receipt: string, notice?: string, status = 200): Promise<Reply> {
  const t = ctx.t;
  const grouped = `${receipt.slice(0, 3)} ${receipt.slice(3)}`;
  return frame(
    ctx,
    t('join.askedTitle'),
    html`<section class="hero">
        <h1>${t('join.askedTitle')}</h1>
        <p class="tagline">${t('join.askedLead')}</p>
      </section>
      ${notice ? html`<p class="notice" role="status">${notice}</p>` : ''}
      <p class="prose-small">${t('join.receipt')}: <span class="receipt">${grouped}</span></p>
      <div class="choices">
        <form method="post" action="/join/received"><button type="submit" class="btn primary px-6 py-2">${t('join.yes')}</button></form>
        <a class="btn px-6 py-2" href="/join/email">${t('join.no')}</a>
      </div>
      <p class="help">${t('join.askedHelp')}</p>`,
    status
  );
}

function emailPage(ctx: Ctx, email: string, error?: string, status = 200): Promise<Reply> {
  const t = ctx.t;
  return frame(
    ctx,
    t('join.noMailTitle'),
    html`<section class="hero">
        <h1>${t('join.noMailTitle')}</h1>
        <p class="tagline">${t('join.noMailLead')}</p>
      </section>
      ${error ? html`<p class="error" role="alert">${error}</p>` : ''}
      <form class="form stack" method="post" action="/join/email">
        <label class="stack-tight">
          <span>${t('join.email')}</span>
          <input type="email" name="email" value="${email}" autocomplete="email" autocapitalize="none" spellcheck="false" maxlength="254" required autofocus />
          <span class="help">${t('join.noMailHelp')}</span>
        </label>
        <button type="submit" class="btn primary px-6 py-2">${t('join.resendReceipt')}</button>
      </form>`,
    status
  );
}

async function donePage(ctx: Ctx, weekday: number, daysAfter: number): Promise<Reply> {
  const t = ctx.t;
  const i = await info(ctx);
  return frame(
    ctx,
    t('join.doneTitle'),
    html`<section class="hero">
        <h1>${t('join.doneTitle')}</h1>
        <p class="tagline">${whenSentence(ctx, i?.greeter ?? null, weekday, daysAfter)} ${t('join.reply')}</p>
      </section>
      <p class="prose-small">${t('join.doneEdit')}</p>
      <p class="prose-small"><a href="/">${t('join.back')}</a></p>`
  );
}

function deadPage(ctx: Ctx): Promise<Reply> {
  const t = ctx.t;
  return frame(
    ctx,
    t('join.deadTitle'),
    html`<section class="hero">
        <h1>${t('join.deadTitle')}</h1>
        <p class="tagline">${t('join.deadLead')}</p>
      </section>
      <p class="prose-small"><a class="btn primary px-6 py-2" href="/join">${t('join.deadLink')}</a></p>`,
    404
  );
}

// ── 書く ─────────────────────────────────────────────────────────

route('GET', '/join', (ctx) => formPage(ctx, { draft: ctx.session?.joinDraft }));

// 送る前に、関所(/check)を通す。メールが出るのは、そこを通った人だけ ── 加入や入るときと同じ順番。
route('POST', '/join', async (ctx) => {
  const draft = draftOf(await ctx.form());
  if (!draft.email) return formPage(ctx, { draft, error: ctx.t('join.errEmail') }, 422);
  const s = ctx.sess();
  s.joinDraft = draft;
  s.check = { intent: 'join', draft };
  saveSession(s);
  return redirect('/check?intent=join');
});

// 関所の先(auth.ts の /check から呼ばれる)。gateway に預けて、「受け取りましたか」へ。
export async function submitJoin(ctx: Ctx, draft: JoinDraft): Promise<Reply> {
  try {
    const r = await gwJson<{ receipt: string; claim: string; weekday: number; days_after: number }>(ctx, 'POST', '/api/v1/join', {
      auth: false,
      json: { ...draft, lang: ctx.locale }
    });
    const s = ctx.sess();
    s.join = { claim: r.claim, receipt: r.receipt, email: draft.email, weekday: r.weekday, daysAfter: r.days_after };
    s.joinDraft = undefined;
    saveSession(s);
    return redirect('/join/asked');
  } catch (e) {
    const f = failure(ctx, e);
    return formPage(ctx, { draft, error: f.error }, f.status);
  }
}

// ── 受け取りましたか ─────────────────────────────────────────────

route('GET', '/join/asked', (ctx) => {
  const j = ctx.session?.join;
  if (!j) return redirect('/join');
  if (j.confirmed) return redirect('/join/done');
  const flash = ctx.takeFlash();
  return askedPage(ctx, j.receipt, flash?.text);
});

route('POST', '/join/received', async (ctx) => {
  const s = ctx.session;
  const j = s?.join;
  if (!s || !j) return redirect('/join');
  try {
    await gw(ctx, 'POST', '/api/v1/join/received', { auth: false, json: { claim: j.claim } });
  } catch (e) {
    // 三時間たって消えた。書き直してもらう(書いたものは、もう残っていない)。
    if (e instanceof GatewayError && e.status === 404) {
      s.join = undefined;
      saveSession(s);
      ctx.flash('notice', ctx.t('join.expired'));
      return redirect('/join');
    }
    const f = failure(ctx, e);
    return askedPage(ctx, j.receipt, f.error, f.status);
  }
  j.confirmed = true;
  saveSession(s);
  return redirect('/join/done');
});

route('GET', '/join/done', (ctx) => {
  const j = ctx.session?.join;
  if (!j) return redirect('/join');
  if (!j.confirmed) return redirect('/join/asked');
  return donePage(ctx, j.weekday, j.daysAfter);
});

// ── いいえ → アドレスを見直す ─────────────────────────────────────

route('GET', '/join/email', (ctx) => {
  const j = ctx.session?.join;
  if (!j) return redirect('/join');
  if (j.confirmed) return redirect('/join/done');
  return emailPage(ctx, j.email);
});

route('POST', '/join/email', async (ctx) => {
  const s = ctx.session;
  const j = s?.join;
  if (!s || !j) return redirect('/join');
  const email = String((await ctx.form()).get('email') ?? '').trim();
  try {
    await gw(ctx, 'POST', '/api/v1/join/email', { auth: false, json: { claim: j.claim, email } });
  } catch (e) {
    if (e instanceof GatewayError && e.status === 409) {
      j.confirmed = true;
      saveSession(s);
      return redirect('/join/done');
    }
    if (e instanceof GatewayError && e.status === 404) {
      s.join = undefined;
      saveSession(s);
      ctx.flash('notice', ctx.t('join.expired'));
      return redirect('/join');
    }
    const f = failure(ctx, e);
    return emailPage(ctx, email, f.error, f.status);
  }
  j.email = email;
  saveSession(s);
  ctx.flash('notice', ctx.t('join.resent'));
  return redirect('/join/asked');
});

// ── メールのリンクから、書き直す ──────────────────────────────────

async function lookup(ctx: Ctx, key: string): Promise<Words | null> {
  try {
    return await gwJson<Words>(ctx, 'POST', '/api/v1/join/lookup', { auth: false, json: { key } });
  } catch (e) {
    if (e instanceof GatewayError && e.status === 404) return null;
    throw e;
  }
}

route('GET', '/join/edit/:key', async (ctx) => {
  const key = ctx.params.key;
  const w = await lookup(ctx, key);
  if (!w) return deadPage(ctx);
  return formPage(ctx, { editKey: key, draft: { call_name: w.call_name ?? '', found: w.found ?? '', hope: w.hope ?? '' } });
});

route('POST', '/join/edit/:key', async (ctx) => {
  const key = ctx.params.key;
  const form = await ctx.form();
  const draft = { call_name: String(form.get('call_name') ?? ''), found: String(form.get('found') ?? ''), hope: String(form.get('hope') ?? '') };
  try {
    await gw(ctx, 'POST', '/api/v1/join/edit', { auth: false, json: { key, ...draft } });
  } catch (e) {
    if (e instanceof GatewayError && e.status === 404) return deadPage(ctx);
    const f = failure(ctx, e);
    return formPage(ctx, { editKey: key, draft, error: f.error }, f.status);
  }
  const t = ctx.t;
  return frame(
    ctx,
    t('join.savedTitle'),
    html`<section class="hero">
        <h1>${t('join.savedTitle')}</h1>
        <p class="tagline">${t('join.savedLead')}</p>
      </section>
      <p class="prose-small"><a href="/">${t('join.back')}</a></p>`
  );
});
