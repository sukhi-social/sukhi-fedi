// SPDX-License-Identifier: AGPL-3.0-or-later
// 入口: はじめる(signup)、入る(login)、OAuth の戻り(callback)、出る(logout)、ことば替え(lang)。
//
// SPA の auth.ts と /check がブラウザでやっていたことを、サーバの手順にした。
//
//   login   password か メールコード → gateway の /login が cookie(session_token)を立てる
//           → その cookie をブラウザへ渡し → /oauth/authorize(gateway)→ /app/callback に戻る
//           → ここで code をトークンに替えて、セッションに仕舞う。ブラウザには札(sukhi_sid)だけ。
//   signup  メール → 6 桁コード → email_proof → アカウント作成 → そのまま入る

import { randomUUID } from "node:crypto";
import { config } from "../config.ts";
import { getClient } from "../client.ts";
import { clientHeaders, endSession, forwardCookies, gw, gwJson, GatewayError } from "../gateway.ts";
import { html, raw, type SafeHtml } from "../html.ts";
import { ok, redirect, route, type Ctx, type Reply } from "../http.ts";
import { saveSession, type Session } from "../session.ts";
import type { TokenSet } from "../types.ts";
import { layout } from "../views/layout.ts";
import { entranceBar, legalFooter } from "../views/parts.ts";
import { timeline } from "./read.ts";
import { isLocale, type TranslationKey } from "../i18n.ts";

// ── OAuth のはじまり ─────────────────────────────────────────────
async function beginOAuth(ctx: Ctx): Promise<Reply> {
  const client = await getClient();
  const s = ctx.sess();
  s.oauthState = randomUUID();
  saveSession(s);
  const qs = new URLSearchParams({
    response_type: "code",
    client_id: client.client_id,
    redirect_uri: client.redirect_uri,
    scope: config.scopes,
    state: s.oauthState,
  });
  return redirect(`/oauth/authorize?${qs}`);
}

// ── 関所(/check)───────────────────────────────────────────────
// anubis が CHALLENGE するのは GET /check だけ。ログインも加入も、ここを経由する ──
// 一段目(合言葉・メールのコード)のあとで /check へ送り、PoW を解いた人だけがここへ届く。
// 通れなかった人は anubis の画面(imprint)で止まり、OAuth もアカウント作成も始まらない。
// 何をするかは、ここでなく session に置く(URL の ?intent= は、行き先の合図にすぎない)。
function toCheck(ctx: Ctx, check: NonNullable<Session["check"]>): Reply {
  const s = ctx.sess();
  s.check = check;
  saveSession(s);
  return redirect(`/check?intent=${check.intent}`);
}

route("GET", "/check", async (ctx) => {
  const h = ctx.req.headers;
  // service worker の先読み(navigation preload)は、本物の要求の前に同じ GET を送ってくる。返事は
  // 捨てられるので、一度きりの手順(メール・OAuth・アカウント作成)を、ここで使い切らせない。
  if (h["service-worker-navigation-preload"] !== undefined) {
    console.log("[check] ignored service-worker navigation preload");
    return { status: 204, headers: { "cache-control": "no-store" }, body: "" };
  }
  const s = ctx.session;
  const intent = ctx.url.searchParams.get("intent");
  const c = s?.check;
  if (!s || !c || c.intent !== intent) {
    // 何が欠けて戻されたか ── 実機でしか起きないので、あとから見分けられるよう残す(メールは書かない)。
    console.log(
      `[check] bounced: ${!s ? (h.cookie?.includes("sukhi_sid=") ? "session-unknown" : "no-cookie") : !c ? "no-pending-step" : "intent-mismatch"} intent=${intent} dest=${c?.intent ?? "-"} sec-fetch=${h["sec-fetch-site"] ?? "-"}/${h["sec-fetch-mode"] ?? "-"}/${h["sec-fetch-dest"] ?? "-"} ua=${String(h["user-agent"] ?? "").slice(0, 80)}`,
    );
    // メールのやりかけが消えた(リロード・タブの復元・二重の要求)。黙って空の /login にせず、一言添える。
    if (intent === "login-email") ctx.flash("notice", ctx.t("check.expired"));
    return redirect(intent === "signup" ? "/signup" : "/login");
  }
  s.check = undefined; // 一度きり。リロードで二度は始まらない(メールも二度は送らない)。
  saveSession(s);
  if (c.intent === "login") return beginOAuth(ctx);
  if (c.intent === "login-email") return sendLoginCode(ctx, c.email);
  // 加入: 証明がまだなら、ここでコードを送る。証明があれば、アカウントを作る。
  if (c.proof === undefined) return sendSignupCode(ctx, c);
  return finishSignup(
    ctx,
    { username: c.username, email: c.email, invite: c.invite },
    c.proof,
  );
});

// メールのコードを送るのは、関所(/check)を通った人だけ。
async function sendLoginCode(ctx: Ctx, email: string): Promise<Reply> {
  try {
    // 知らないアドレスにも 200 が返る(居る/居ないを言わない)ので、送った前提で次の画面へ。
    await gw(ctx, "POST", "/login/email/request", {
      auth: false,
      json: { email, lang: ctx.locale },
    });
    return loginPage(ctx, { method: "email", step: "code", email });
  } catch (e) {
    const msg = e instanceof GatewayError ? e.message : "";
    const status = e instanceof GatewayError ? e.status : 0;
    const error =
      msg === "rate_limited" || status === 429
        ? ctx.t("login.rateLimited")
        : ctx.t("login.failed");
    return loginPage(ctx, { method: "email", email, error }, 422);
  }
}

async function sendSignupCode(
  ctx: Ctx,
  v: { username: string; email: string; invite: string },
): Promise<Reply> {
  const view: SignupView = {
    username: v.username,
    email: v.email,
    invite: v.invite,
  };
  try {
    await gw(ctx, "POST", "/signup/email/request", {
      auth: false,
      json: { email: v.email, lang: ctx.locale },
    });
    return signupPage(ctx, { ...view, step: "code" });
  } catch (e) {
    return signupPage(
      ctx,
      {
        ...view,
        needInvite: await inviteRequired(ctx),
        error: signupStepError(ctx, e),
      },
      422,
    );
  }
}

route("GET", "/app/callback", async (ctx) => {
  const q = ctx.url.searchParams;
  const fail = (text: string) =>
    ok(
      layout(ctx, {
        title: ctx.t("callback.failedTitle"),
        entrance: true,
        body: html`<section class="hero">
            <h1>${ctx.t("callback.failedTitle")}</h1>
            <p class="tagline">${text}</p>
          </section>
          <p class="prose-small">
            <a href="/">${ctx.t("common.backToTop")}</a>
          </p>`,
      }),
      400,
    );

  const err = q.get("error");
  if (err) return fail(ctx.t("callback.serverError", { err }));
  const code = q.get("code");
  const state = q.get("state");
  if (!code || !state) return fail(ctx.t("callback.urlMissing"));

  const s = ctx.session;
  if (!s?.oauthState || s.oauthState !== state) return fail("state mismatch");
  s.oauthState = undefined;

  const client = await getClient();
  const res = await fetch(`${config.gateway}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/json", ...clientHeaders(ctx) },
    body: JSON.stringify({
      grant_type: "authorization_code",
      code,
      client_id: client.client_id,
      client_secret: client.client_secret,
      redirect_uri: client.redirect_uri,
    }),
  });
  if (!res.ok) return fail(`token exchange failed: ${res.status}`);
  s.token = (await res.json()) as TokenSet;
  s.me = undefined; // アカウントが替わったかもしれない。引きなおす。
  saveSession(s);
  await ctx.me().catch(() => null); // 言語を、最初の画面から使うため、いまのうちに引いておく。
  return redirect("/");
});

// ── login ───────────────────────────────────────────────────────
type LoginView = {
  method?: "email" | "password";
  step?: "first" | "code" | "totp";
  email?: string;
  pending?: string;
  error?: string;
};

// 入り口の種類。welcome=はじめての人(加入を目立たせる)、again=ログインが切れた人(そっと)。
function loginMode(ctx: Ctx): "welcome" | "again" | null {
  const q = ctx.url.searchParams;
  return q.get("welcome") === "true" ? "welcome" : q.get("again") === "true" ? "again" : null;
}

function loginPage(ctx: Ctx, v: LoginView = {}, status = 200): Reply {
  const t = ctx.t;
  const step = v.step ?? "first";
  const mode = loginMode(ctx);
  // 入り口の種類(?welcome / ?again)は、二段目や、やりなおしでも持ちまわる。
  const action = mode ? `/login?${mode}=true` : "/login";
  const joinFirst = mode === "welcome" && step === "first";
  const body = html`<div class="measure stack">
    <section class="hero">
      <h1>${t("login.title")}</h1>
      <p class="tagline">${t("login.tagline")}</p>
    </section>
    ${mode === "again" && step === "first" ? html`<p class="notice">${t("login.again")}</p>` : ""}
    ${
      joinFirst
        ? html`<a class="lane-door" data-lane="use" href="/signup"
            ><h3>${t("landing.startTitle")}</h3>
            <p>${t("landing.startDesc")}</p></a
          >`
        : ""
    }
    ${v.error ? html`<p class="error" role="alert">${v.error}</p>` : ""}
    ${
      step === "totp"
        ? html`<section class="section">
              <h2 class="text-base">${t("login.totpTitle")}</h2>
              <p class="prose-small">${t("login.totpHelp")}</p>
            </section>
            <form class="form stack" method="post" action="${action}">
              <input type="hidden" name="step" value="totp" />
              <input type="hidden" name="pending" value="${v.pending}" />
              <label class="stack-tight"
                ><span>${t("login.code")}</span>
                <input
                  type="text"
                  name="code"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  pattern="[0-9]{6}"
                  required
                  autofocus
                />
              </label>
              <button type="submit" class="btn primary px-6 py-2">
                ${t("login.submit")}
              </button>
            </form>`
        : step === "code"
          ? html`<section class="section">
                <p class="prose-small">
                  ${t("check.codeSentTo", { email: v.email ?? "" })}
                </p>
              </section>
              <form class="form stack" method="post" action="${action}">
                <input type="hidden" name="method" value="email" />
                <input type="hidden" name="step" value="confirm" />
                <input type="hidden" name="email" value="${v.email}" />
                <label class="stack-tight"
                  ><span>${t("login.code")}</span>
                  <input
                    type="text"
                    name="code"
                    inputmode="numeric"
                    autocomplete="one-time-code"
                    pattern="[0-9]{6}"
                    required
                    autofocus
                  />
                </label>
                <button type="submit" class="btn primary px-6 py-2">
                  ${t("login.submit")}
                </button>
              </form>
              <form method="post" action="${action}">
                <input type="hidden" name="method" value="email" />
                <input type="hidden" name="step" value="request" />
                <input type="hidden" name="email" value="${v.email}" />
                <button type="submit" class="chip">
                  ${t("login.sendAgain")}
                </button>
              </form>`
          : html`<div
                x-data="{ method: '${v.method ?? "email"}' }"
                class="stack"
              >
                <div
                  class="method-switch"
                  role="tablist"
                  aria-label="${t("login.methodLabel")}"
                >
                  <button
                    type="button"
                    class="chip"
                    role="tab"
                    :aria-selected="method === 'email'"
                    @click="method = 'email'"
                  >
                    ${t("login.methodEmail")}
                  </button>
                  <button
                    type="button"
                    class="chip"
                    role="tab"
                    :aria-selected="method === 'password'"
                    @click="method = 'password'"
                  >
                    ${t("login.methodPassword")}
                  </button>
                </div>
                <form
                  class="form stack"
                  method="post"
                  action="${action}"
                  x-show="method === 'email'"
                >
                  <input type="hidden" name="method" value="email" />
                  <input type="hidden" name="step" value="request" />
                  <label class="stack-tight"
                    ><span>${t("login.email")}</span>
                    <input
                      type="email"
                      name="email"
                      value="${v.email ?? ""}"
                      autocomplete="email"
                      autocapitalize="none"
                      spellcheck="false"
                      required
                    />
                    <span class="help">${t("login.emailHelp")}</span>
                  </label>
                  <button type="submit" class="btn primary px-6 py-2">
                    ${t("login.sendCode")}
                  </button>
                </form>
                <form
                  class="form stack"
                  method="post"
                  action="${action}"
                  x-show="method === 'password'"
                  x-cloak
                >
                  <input type="hidden" name="method" value="password" />
                  <label class="stack-tight"
                    ><span>${t("login.handle")}</span>
                    <input
                      type="text"
                      name="username"
                      autocomplete="username"
                      autocapitalize="none"
                      autocorrect="off"
                      spellcheck="false"
                      required
                    />
                  </label>
                  <label class="stack-tight"
                    ><span>${t("login.password")}</span>
                    <input
                      type="password"
                      name="password"
                      autocomplete="current-password"
                      required
                    />
                  </label>
                  <button type="submit" class="btn primary px-6 py-2">
                    ${t("login.submit")}
                  </button>
                </form>
              </div>
              ${
                joinFirst
                  ? ""
                  : html`<p class="prose-small">
                      <a href="/signup">${t("login.toSignup")}</a>
                    </p>`
              }
              <p class="prose-small">
                <a href="/">${t("signup.backToFront")}</a>
              </p>`
    }
  </div>`;
  return ok(
    layout(ctx, { title: t("login.title"), entrance: true, body }),
    status,
  );
}

route("GET", "/login", async (ctx) => {
  if (ctx.session?.token) return redirect("/");
  return loginPage(ctx);
});

// 一段目が通ったあと。cookie を、ブラウザへ渡して OAuth へ。2FA の人は二段目へ。
async function afterFirstFactor(ctx: Ctx, res: Response): Promise<Reply> {
  const body = (await res.json().catch(() => ({}))) as {
    second_factor?: string;
    pending?: string;
  };
  if (body.second_factor && body.pending) {
    return loginPage(ctx, { step: "totp", pending: body.pending });
  }
  forwardCookies(ctx, res);
  return toCheck(ctx, { intent: "login" });
}

route("POST", "/login", async (ctx) => {
  const t = ctx.t;
  const f = await ctx.form();
  const str = (k: string) => String(f.get(k) ?? "").trim();
  const method = str("method") === "password" ? "password" : "email";
  const step = str("step");

  try {
    if (step === "totp") {
      const res = await gw(ctx, "POST", "/login/totp", {
        auth: false,
        json: { pending: str("pending"), code: str("code") },
      });
      forwardCookies(ctx, res);
      return toCheck(ctx, { intent: "login" });
    }
    if (method === "password") {
      const res = await gw(ctx, "POST", "/login", {
        auth: false,
        json: {
          username: str("username"),
          password: String(f.get("password") ?? ""),
        },
      });
      return afterFirstFactor(ctx, res);
    }
    const email = str("email");
    if (step === "confirm") {
      const res = await gw(ctx, "POST", "/login/email", {
        auth: false,
        json: { email, code: str("code") },
      });
      return afterFirstFactor(ctx, res);
    }
    // コードを送るのは、関所(/check)を通ってから。ここでは行き先を預けるだけ。
    if (!email) return loginPage(ctx, { method: "email", error: t("login.failed") }, 422);
    return toCheck(ctx, { intent: "login-email", email });
  } catch (e) {
    const msg = e instanceof GatewayError ? e.message : "";
    const status = e instanceof GatewayError ? e.status : 0;
    const again = (error: string): Reply => {
      if (step === "totp")
        return loginPage(
          ctx,
          { step: "totp", pending: str("pending"), error },
          422,
        );
      if (step === "confirm")
        return loginPage(
          ctx,
          { method: "email", step: "code", email: str("email"), error },
          422,
        );
      return loginPage(
        ctx,
        { method, email: method === "email" ? str("email") : undefined, error },
        422,
      );
    };
    if (step === "totp") {
      if (msg === "pending")
        return loginPage(ctx, { method, error: t("login.totpExpired") }, 422);
      if (msg === "rate_limited") return again(t("login.rateLimited"));
      return again(t("login.totpFailed"));
    }
    if (msg === "rate_limited" || status === 429)
      return again(t("login.rateLimited"));
    if (method === "password" && status === 401)
      return again(t("login.invalid"));
    if (step === "confirm") {
      return again(
        msg === "code"
          ? t("security.codeWrong")
          : msg === "expired"
            ? t("security.codeExpired")
            : t("login.failed"),
      );
    }
    return again(t("login.failed"));
  }
});

// ── signup ──────────────────────────────────────────────────────
const SIGNUP_ERRORS: Record<string, TranslationKey> = {
  invite_code_required: "check.err.invite_code_required",
  invite_invalid: "check.err.invite_invalid",
  invite_used: "check.err.invite_used",
  invite_expired: "check.err.invite_expired",
  password_too_short: "check.err.password_too_short",
  email_proof_invalid: "check.err.email_proof_invalid",
  validation_failed: "check.err.validation_failed",
  client_credentials_required: "check.err.client_credentials_required",
  token_mint_failed: "check.err.token_mint_failed",
  gateway_not_connected: "check.err.gateway_not_connected",
  gateway_rpc_failed: "check.err.gateway_rpc_failed",
  internal_error: "check.err.internal_error",
};
const SIGNUP_FIELDS: Record<string, TranslationKey> = {
  username: "check.field.username",
  password: "check.field.password",
  email: "check.field.email",
  invite_code: "check.field.invite_code",
};

// 招待コードが要るサーバかどうかは、サーバが決める。訊けなかったら「要る」に倒す
// (欄が余分に出るより、隠れた必須欄のほうが困る)。
async function inviteRequired(ctx: Ctx): Promise<boolean> {
  try {
    const i = await gwJson<{ registrations?: { approval_required?: boolean } }>(
      ctx,
      "GET",
      "/api/v2/instance",
      { auth: false },
    );
    return i.registrations?.approval_required !== false;
  } catch {
    return true;
  }
}

type SignupView = {
  username?: string;
  email?: string;
  invite?: string;
  step?: "first" | "code";
  error?: string;
  needInvite?: boolean;
};

function signupPage(ctx: Ctx, v: SignupView = {}, status = 200): Reply {
  const t = ctx.t;
  const lang = ctx.locale === "ko" ? "&lang=ko" : "";
  const termsAnchor = html`<a
    href="/terms?signup=true${lang}"
    target="_blank"
    up-follow="false"
    >${t("signup.termsLink")}</a
  >`;
  const privacyAnchor = html`<a
    href="/privacy?signup=true${lang}"
    target="_blank"
    up-follow="false"
    >${t("signup.privacyLink")}</a
  >`;
  // 文は一文のまま辞書に持ち、リンクだけ差し込む(語順・助詞は言語ごとに一文の中で完結する)。
  const sentence = (key: TranslationKey, parts: Record<string, SafeHtml>) =>
    raw(
      t(key).replace(/\{(\w+)\}/g, (m, k: string) =>
        parts[k] ? parts[k].value : m,
      ),
    );

  const hidden = html`<input
      type="hidden"
      name="username"
      value="${v.username}"
    /><input type="hidden" name="email" value="${v.email}" /><input
      type="hidden"
      name="invite_code"
      value="${v.invite ?? ""}"
    />`;
  const body = html`<div class="measure">
    <section class="hero">
      <h1>${t("signup.title")}</h1>
      <p class="tagline">${t("signup.tagline")}</p>
    </section>
    ${v.error ? html`<p class="error" role="alert">${v.error}</p>` : ""}
    ${
      v.step === "code"
        ? html`<p class="prose-small">
              ${t("check.codeSentTo", { email: v.email ?? "" })}
            </p>
            <form class="form stack" method="post" action="/signup">
              <input type="hidden" name="step" value="confirm" /><input
                type="hidden"
                name="agree"
                value="1"
              />${hidden}
              <label class="stack-tight"
                ><span>${t("login.code")}</span>
                <input
                  type="text"
                  name="code"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  pattern="[0-9]{6}"
                  required
                  autofocus
                />
              </label>
              <button type="submit" class="btn primary px-6 py-2">
                ${t("signup.create")}
              </button>
            </form>
            <form method="post" action="/signup">
              <input type="hidden" name="step" value="request" /><input
                type="hidden"
                name="agree"
                value="1"
              />${hidden}
              <button type="submit" class="chip">
                ${t("login.sendAgain")}
              </button>
            </form>`
        : html`<p class="read-first">
              ${sentence("signup.readFirst", { link: termsAnchor })}
            </p>
            <form
              class="form stack"
              method="post"
              action="/signup"
              x-data="{ agreed: false }"
            >
              <input type="hidden" name="step" value="request" />
              <label class="stack-tight"
                ><span>${t("signup.email")}</span>
                <input
                  type="email"
                  name="email"
                  value="${v.email ?? ""}"
                  autocomplete="email"
                  autocapitalize="none"
                  spellcheck="false"
                  required
                />
                <span class="help">${t("signup.emailHelp")}</span>
              </label>
              <label class="stack-tight"
                ><span>${t("signup.handle")}</span>
                <div class="handle-field">
                  <span class="handle-at" aria-hidden="true">@</span>
                  <input
                    type="text"
                    name="username"
                    value="${v.username ?? ""}"
                    autocomplete="username"
                    pattern="[a-z0-9_]{1,30}"
                    title="${t("signup.handleTitle")}"
                    required
                  />
                </div>
                <span class="help"
                  >${t("signup.handleHelpPre")}<code>@usagi_05</code></span
                >
              </label>
              ${
                v.needInvite !== false
                  ? html`<label class="stack-tight"
                      ><span>${t("signup.inviteCode")}</span
                      ><input
                        type="text"
                        name="invite_code"
                        value="${v.invite ?? ""}"
                        autocomplete="off"
                        required
                    /></label>`
                  : ""
              }
              <label class="agree">
                <input
                  type="checkbox"
                  name="agree"
                  value="1"
                  x-model="agreed"
                  required
                />
                <span
                  >${sentence("signup.agree", { terms: termsAnchor, privacy: privacyAnchor })}</span
                >
              </label>
              <button
                type="submit"
                class="btn primary px-6 py-2"
                :disabled="!agreed"
              >
                ${t("signup.create")}
              </button>
            </form>
            <p class="prose-small after-form">
              ${t("signup.haveAccountPre")}<a href="/login"
                >${t("signup.haveAccountLink")}</a
              >${t("signup.haveAccountPost")}
            </p>
            <p class="prose-small">
              <a href="/">${t("signup.backToFront")}</a>
            </p>`
    }
  </div>`;
  return ok(
    layout(ctx, { title: t("signup.title"), entrance: true, body }),
    status,
  );
}

// 加入の段で gateway が返した理由を、ことばにする。
function signupStepError(ctx: Ctx, e: unknown): string {
  const t = ctx.t;
  const msg = e instanceof GatewayError ? e.message : "";
  if (msg === "code") return t("security.codeWrong");
  if (msg === "expired") return t("security.codeExpired");
  if (msg === "too_many_attempts" || msg === "rate_limited")
    return t("login.rateLimited");
  if (msg === "email_taken") return t("security.emailTaken");
  if (msg === "email") return t("security.emailInvalid");
  if (msg === "send_failed") return t("security.sendFailed");
  return t("common.deliverFailed");
}

route("GET", "/signup", async (ctx) => {
  if (ctx.session?.token) return redirect("/");
  return signupPage(ctx, {
    ...ctx.session?.signupDraft,
    needInvite: await inviteRequired(ctx),
  });
});

route("POST", "/signup", async (ctx) => {
  const t = ctx.t;
  const f = await ctx.form();
  const str = (k: string) => String(f.get(k) ?? "").trim();
  const v: SignupView = {
    username: str("username"),
    email: str("email"),
    invite: str("invite_code"),
  };
  const step = str("step");

  const stepFail = (e: unknown): string => signupStepError(ctx, e);

  if (
    !/^[a-z0-9_]{1,30}$/.test(v.username ?? "") ||
    !v.email ||
    f.get("agree") !== "1"
  ) {
    return signupPage(
      ctx,
      {
        ...v,
        needInvite: await inviteRequired(ctx),
        error: t("check.err.validation_failed"),
      },
      422,
    );
  }

  // 下書きは session に置く(/signup に戻ったとき埋める。同意は埋めない)。
  const sess = ctx.sess();
  sess.signupDraft = {
    username: v.username ?? "",
    email: v.email ?? "",
    invite: v.invite ?? "",
  };
  saveSession(sess);

  // 一段目: 6 桁のコードは、関所(/check)を通ってから送る。ここでは行き先を預けるだけ。
  if (step !== "confirm") {
    return toCheck(ctx, {
      intent: "signup",
      username: v.username ?? "",
      email: v.email ?? "",
      invite: v.invite ?? "",
    });
  }

  // 二段目: コード → 証明 → アカウント作成 → そのまま入る。
  let proof: string;
  try {
    const r = await gwJson<{ email_proof: string }>(
      ctx,
      "POST",
      "/signup/email/confirm",
      { auth: false, json: { email: v.email, code: str("code") } },
    );
    proof = r.email_proof;
  } catch (e) {
    return signupPage(ctx, { ...v, step: "code", error: stepFail(e) }, 422);
  }

  // アカウントを作るのは、関所(/check)を通ってから。
  return toCheck(ctx, {
    intent: "signup",
    username: v.username ?? "",
    email: v.email ?? "",
    invite: v.invite ?? "",
    proof,
  });
});

// 関所を通った人のアカウントを作る。作れたら、そのまま入る。
async function finishSignup(
  ctx: Ctx,
  v: SignupView,
  proof: string,
): Promise<Reply> {
  const t = ctx.t;
  try {
    const client = await getClient();
    const cc = await fetch(`${config.gateway}/oauth/token`, {
      method: "POST",
      headers: { "content-type": "application/json", ...clientHeaders(ctx) },
      body: JSON.stringify({
        grant_type: "client_credentials",
        client_id: client.client_id,
        client_secret: client.client_secret,
        scope: config.scopes,
      }),
    });
    if (!cc.ok)
      throw new GatewayError("client_credentials_required", cc.status);
    const app = (await cc.json()) as TokenSet;

    const res = await fetch(`${config.gateway}/api/v1/accounts`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${app.access_token}`,
        ...clientHeaders(ctx),
      },
      body: JSON.stringify({
        username: v.username,
        invite_code: v.invite,
        email_proof: proof,
      }),
    });
    const made = (await res.json().catch(() => ({}))) as TokenSet & {
      error?: string;
      details?: Record<string, string[]>;
    };
    if (!res.ok)
      throw new GatewayError(
        made.error ?? `signup_failed_${res.status}`,
        res.status,
        made.details,
      );

    const s = ctx.sess();
    s.token = made;
    s.me = undefined;
    s.signupDraft = undefined;
    saveSession(s);
    await ctx.me().catch(() => null);

    // メールで加入した人も、パスワードログインと同じ地位に(cookie 専用の管理面が、二度目のログイン無しで開くように)。
    // best-effort: 失敗しても、その画面に来たときメールの道で入りなおせる。
    try {
      forwardCookies(
        ctx,
        await gw(ctx, "POST", "/signup/session", {
          auth: false,
          json: { email_proof: proof },
        }),
      );
    } catch {
      // そっとしておく。
    }
    return redirect("/");
  } catch (e) {
    const msg = e instanceof GatewayError ? e.message : "";
    // 証明が古かったときだけ、コードの段から。
    if (msg === "email_proof_invalid") {
      return signupPage(
        ctx,
        {
          ...v,
          needInvite: await inviteRequired(ctx),
          error: t("check.err.email_proof_invalid"),
        },
        422,
      );
    }
    let error = t("check.failedGeneric");
    if (msg === "validation_failed" && e instanceof GatewayError && e.details) {
      const [field, msgs] = Object.entries(e.details)[0] ?? [];
      if (field)
        error = `${SIGNUP_FIELDS[field] ? t(SIGNUP_FIELDS[field]) : field}${msgs?.[0] ?? ""}`;
    } else if (SIGNUP_ERRORS[msg]) {
      error = t(SIGNUP_ERRORS[msg]);
    }
    return signupPage(
      ctx,
      { ...v, needInvite: await inviteRequired(ctx), error },
      422,
    );
  }
}

// ── logout / lang ───────────────────────────────────────────────
route("POST", "/logout", async (ctx) => {
  await endSession(ctx);
  return redirect("/");
});

route("POST", "/lang", async (ctx) => {
  const f = await ctx.form();
  const l = String(f.get("l") ?? "");
  const next = String(f.get("next") ?? "/");
  if (isLocale(l)) ctx.setCookie("sukhi_locale", l);
  // 戻り先は、この郵便局の中だけ。
  return redirect(next.startsWith("/") && !next.startsWith("//") ? next : "/");
});

// ── 入口(トップ) ───────────────────────────────────────────────
// 入っている人 → ここがホーム(/timeline は付けない)。
// はじめての人 → about へ(ABOUT_URL が空なら、ここの入口を見せる)。
// 札(sukhi_sid)はあるのに入っていない人 → 切れたとみて、/login?again=true へ。
route("GET", "/", async (ctx) => {
  if (ctx.session?.token) return timeline(ctx, null);
  if (/(?:^|;\s*)sukhi_sid=/.test(ctx.req.headers.cookie ?? ""))
    return redirect("/login?again=true");
  if (config.aboutUrl) return redirect(config.aboutUrl, 302);
  const t = ctx.t;
  const door = (
    href: string,
    lane: "use" | "build",
    title: string,
    desc: string,
  ) =>
    html`<a class="lane-door" data-lane="${lane}" href="${href}"
      ><h3>${title}</h3>
      <p>${desc}</p></a
    >`;
  const body = html`${entranceBar(ctx)}
    <div class="measure">
      <section class="hero">
        <h1>${t("landing.heroTitle")}</h1>
        <p class="tagline">${raw(t("landing.tagline"))}</p>
      </section>
      <section class="section">
        <div class="doors">
          ${door("/signup", "use", t("landing.startTitle"), t("landing.startDesc"))}
          ${door("/login", "build", t("landing.enterTitle"), t("landing.enterDesc"))}
        </div>
      </section>
      <section class="section">
        <p class="prose-small">${t("landing.about")}</p>
        <p class="prose-small">
          ${t("landing.peek")}<a href="/timeline">${t("landing.peekLink")}</a>
        </p>
      </section>
    </div>
    ${legalFooter(ctx)}`;
  // 入口の帯は body の中に自前で置く(layout の entrance は使わない: 二重になるため)。
  return ok(layout(ctx, { title: "", body }));
});
