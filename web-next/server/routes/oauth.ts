// SPDX-License-Identifier: AGPL-3.0-or-later
// 同意の頁。/oauth/authorize ── 外のアプリ(Mastodon のクライアントなど)が、人をここへ連れてくる。
//
// 決めるのは、gateway の api(GET/POST /api/v1/sukhi/oauth/authorize)。ここは、その決定を絵にして、
// ブラウザの cookie(session_token / session_tokens)をそのまま添えて聞くだけ:
//
//   login    入っていない → /login へ。入れたら、この問いに戻る(session.next)
//   pick     いくつも入っている → 「どのアカウントで?」(選ぶと choose=<id> で、同じ問いにもどる)
//   consent  外のアプリ → 「許可しますか?」(自分の web への戻りは、頁なしで通る)
//   redirect その場所へ(コードはもう作ってある)
//
// 自分(web-next)が入るときの OAuth も、ここを通る。戻り先が自分の host のとき、api は頁を出さずに redirect を返す。

import { config } from '../config.ts';
import { gwBrowser } from '../gateway.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import { saveSession } from '../session.ts';
import { consentPage, CONSENT_CSP, pickPage, problemPage, type Asked } from '../views/oauth.ts';

const API = '/api/v1/sukhi/oauth/authorize';
// api に渡す問いの名前。これ以外は、渡さない。
// code_challenge(+method) は PKCE(静的な頁のアプリが、secret なしで入るため)。そのまま、同意の form にも運ぶ。
const ASKED = ['client_id', 'redirect_uri', 'scope', 'state', 'response_type', 'choose', 'code_challenge', 'code_challenge_method'] as const;

type Decision =
  | { decision: 'login' }
  | { decision: 'pick'; accounts: { id: number; username: string }[] }
  | { decision: 'consent'; app: { name: string }; scopes: string[] }
  | { decision: 'redirect'; location: string };
type Problem = { error?: string; error_description?: string };

// 入りなおして、この問いに戻る。web-next の札(token)が残っていると /login は「もう入っている」と
// トップへ返してしまう ── 札はあっても、ブラウザの session cookie は無い。札を外して、入りなおす。
// 戻る先(session.next)を置くのは、外のアプリの問いだけ。自分(この郵便局)が入るときの問いは、
// 入ったあとの /check が、新しい state でやりなおす ── 古い state の問いに戻ると、戻りで食いちがう。
function toLogin(ctx: Ctx, asked: URLSearchParams): Reply {
  const s = ctx.sess();
  if (!ownHost(asked.get('redirect_uri'))) s.next = `/oauth/authorize?${asked}`;
  s.token = undefined;
  s.me = undefined;
  saveSession(s);
  return redirect('/login?again=true');
}

function ownHost(uri: string | null): boolean {
  try {
    return new URL(uri ?? '').host === new URL(config.publicOrigin).host;
  } catch {
    return false;
  }
}

function problem(ctx: Ctx, status: number, body: Problem): Reply {
  return ok(problemPage(ctx, body.error ?? 'error', body.error_description ?? '', status === 503), status);
}

// api の Set-Cookie(選んだアカウントを先頭に並べかえた cookie)を、ブラウザへ ── この応答だけが、運べる。
function relay(ctx: Ctx, setCookies: string[]): void {
  for (const c of setCookies) ctx.cookies.push(c);
}

route('GET', '/oauth/authorize', async (ctx) => {
  const asked = new URLSearchParams();
  for (const k of ASKED) {
    const v = ctx.url.searchParams.get(k);
    if (v !== null) asked.set(k, v);
  }

  const r = await gwBrowser<Decision & Problem>(ctx, 'GET', `${API}?${asked}`);
  if (r.status !== 200 || !('decision' in r.body)) return problem(ctx, r.status, r.body);
  relay(ctx, r.setCookies);
  const d = r.body as Decision;

  switch (d.decision) {
    case 'login':
      return toLogin(ctx, asked);
    case 'pick':
      return ok(pickPage(ctx, d.accounts, withoutChoose(asked)));
    case 'consent': {
      const q = (k: string) => asked.get(k) ?? '';
      const form: Asked = { client_id: q('client_id'), redirect_uri: q('redirect_uri'), scope: q('scope') || 'read', state: q('state'), code_challenge: q('code_challenge'), code_challenge_method: q('code_challenge_method') };
      return ok(consentPage(ctx, d.app, d.scopes, form), 200, { 'content-security-policy': CONSENT_CSP });
    }
    case 'redirect':
      return redirect(d.location);
  }
});

route('POST', '/oauth/authorize', async (ctx) => {
  const f = await ctx.form();
  const str = (k: string) => String(f.get(k) ?? '');
  const sent: Record<string, string> = { client_id: str('client_id'), redirect_uri: str('redirect_uri'), scope: str('scope') || 'read', state: str('state') };
  for (const k of ['code_challenge', 'code_challenge_method']) if (str(k)) sent[k] = str(k);
  const r = await gwBrowser<Decision & Problem>(ctx, 'POST', API, sent);
  if (r.status === 401) {
    // 同意を押すまでのあいだに、入っていたのが切れた。もういちど入って、同じ問いから。
    return toLogin(ctx, new URLSearchParams({ ...sent, response_type: 'code' }));
  }
  if (r.status !== 200 || !('decision' in r.body) || r.body.decision !== 'redirect') return problem(ctx, r.status, r.body);
  return redirect(r.body.location);
});

function withoutChoose(q: URLSearchParams): URLSearchParams {
  const out = new URLSearchParams(q);
  out.delete('choose');
  return out;
}
