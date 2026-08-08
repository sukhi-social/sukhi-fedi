<script lang="ts">
  // 共通の「通り道」。Anubis がこの path だけを CHALLENGE するので、
  // ここに来た時点で PoW は通過済み。メールの 6 桁コードの送信と
  // 入力も、この上で行う ─ 「メールは Anubis の後」の置き場所。
  //
  //   /check?intent=login        → OAuth コードフローを始める(従来)
  //   /check?intent=signup       → コード送信 → 入力 → 証明 →
  //                                POST /api/v1/accounts → timeline
  //   /check?intent=login-email  → コード送信 → 入力 → cookie
  //                                (2FA の人は totp の段) → OAuth へ
  //
  // 失敗した場合は、その場で「もう一度試す」かフォームへの戻り道を
  // 出す ─ 下書き(signup の場合)は残っているので入力し直しは要らない。
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    startLogin,
    signup,
    establishSignupSession,
    loginWithEmailCode,
    requestEmailLoginCode,
    requestSignupEmailCode,
    confirmSignupEmailCode,
    submitTotp,
    loadSignupDraft,
    saveSignupDraft,
    clearSignupDraft,
    clearSignupPassword,
    loadLoginEmail,
    clearLoginEmail
  } from '$lib/auth';
  import { t, type TranslationKey } from '$lib/i18n';

  let phase = $state<'working' | 'code' | 'totp' | 'error'>('working');
  let intent = $state<'login' | 'signup' | 'login-email' | null>(null);
  let error = $state<string | null>(null);

  // code/totp 段のための状態。fatal な error と違って、この段の
  // 失敗(コード違い等)はその場に留まる。
  let email = $state('');
  let code = $state('');
  let totpCode = $state('');
  let pending = $state('');
  let busy = $state(false);
  let stepError = $state<string | null>(null);
  let stepNotice = $state<string | null>(null);
  let next: string | null = null;
  // マルチアカウントの「追加」入り口(login.ts の addMode と同じ約束)。
  // login-email のときだけ意味を持つ ─ loginWithEmailCode/submitTotp へ
  // そのまま引き継ぐ。
  let addMode = false;

  // 直近 10 分以内に同じ宛先へ送っていたら、auto-send を黙って
  // 飛ばす(リロード連打で rate limit を食わないように)。コードの
  // 有効期限と同じ素材なので、前のコードがそのまま使える。
  const SENT_KEY = 'sf.check_code_sent';

  function recentlySent(kind: string, to: string): boolean {
    try {
      const raw = sessionStorage.getItem(SENT_KEY);
      if (!raw) return false;
      const v = JSON.parse(raw) as { kind: string; to: string; at: number };
      return v.kind === kind && v.to === to && Date.now() - v.at < 10 * 60 * 1000;
    } catch {
      return false;
    }
  }

  function markSent(kind: string, to: string): void {
    sessionStorage.setItem(SENT_KEY, JSON.stringify({ kind, to, at: Date.now() }));
  }

  // API (api/lib/sukhi_api/capabilities/mastodon_accounts.ex) が
  // 実際に返すキーに揃える。新しいキーをサーバに足したら、ここも
  // 一緒に書く。
  const ERROR_KEYS: Record<string, TranslationKey> = {
    invite_code_required: 'check.err.invite_code_required',
    invite_invalid: 'check.err.invite_invalid',
    invite_used: 'check.err.invite_used',
    invite_expired: 'check.err.invite_expired',
    password_too_short: 'check.err.password_too_short',
    email_proof_invalid: 'check.err.email_proof_invalid',
    validation_failed: 'check.err.validation_failed',
    client_credentials_required: 'check.err.client_credentials_required',
    token_mint_failed: 'check.err.token_mint_failed',
    gateway_not_connected: 'check.err.gateway_not_connected',
    gateway_rpc_failed: 'check.err.gateway_rpc_failed',
    internal_error: 'check.err.internal_error',
    no_draft: 'check.err.no_draft'
  };

  // changeset の details: {username: ["...", ...]} の field を言語へ。
  // 一個目だけ拾えば十分(複数あっても見せると目が散る)。
  const FIELD_KEYS: Record<string, TranslationKey> = {
    username: 'check.field.username',
    password: 'check.field.password',
    email: 'check.field.email',
    invite_code: 'check.field.invite_code'
  };

  function formatValidation(details: Record<string, string[]> | undefined): string | null {
    if (!details) return null;
    const first = Object.entries(details)[0];
    if (!first) return null;
    const [field, msgs] = first;
    const label = FIELD_KEYS[field] ? $t(FIELD_KEYS[field]) : field;
    const msg = msgs?.[0] ?? '';
    return `${label}${msg}`;
  }

  function fatal(e: unknown): void {
    const msg = e instanceof Error ? e.message : 'unknown';
    const details = (e as Error & { details?: Record<string, string[]> })?.details;
    const fieldHint = msg === 'validation_failed' ? formatValidation(details) : null;
    error = fieldHint ?? (ERROR_KEYS[msg] ? $t(ERROR_KEYS[msg]) : null) ?? $t('check.failedGeneric');
    phase = 'error';
  }

  // コード段のエラー(その場で直せるもの)。'anubis' = XHR に challenge
  // の HTML が返った。読み直しで直ることがある(PoW 再走)が、この
  // Anubis は XHR を cookie 有りでも challenge し直すことが分かって
  // いる(2026-06-13 の無限ループ)ので、reload は一回だけ ─ 二度目は
  // ことばで止まる。ループより、止まるほうがいい。
  const RELOADED_KEY = 'sf.check_reloaded';

  function stepFail(e: unknown): void {
    const msg = e instanceof Error ? e.message : '';
    if (msg === 'anubis') {
      if (!sessionStorage.getItem(RELOADED_KEY)) {
        sessionStorage.setItem(RELOADED_KEY, '1');
        window.location.reload();
      } else {
        stepError = $t('common.deliverFailedRetry');
      }
      return;
    }
    stepError =
      msg === 'code'
        ? $t('security.codeWrong')
        : msg === 'expired'
          ? $t('security.codeExpired')
          : msg === 'too_many_attempts' || msg === 'rate_limited'
            ? $t('login.rateLimited')
            : msg === 'email_taken'
              ? $t('security.emailTaken')
              : msg === 'email'
                ? $t('security.emailInvalid')
                : msg === 'send_failed'
                  ? $t('security.sendFailed')
                  : $t('common.deliverFailed');
  }

  onMount(async () => {
    const params = new URLSearchParams(window.location.search);
    const i = params.get('intent');
    const n = params.get('next');
    next = n && n.startsWith('/') ? n : null;
    addMode = params.get('mode') === 'add';

    if (i !== 'login' && i !== 'signup' && i !== 'login-email') {
      error = $t('check.unknownIntent');
      phase = 'error';
      return;
    }

    intent = i;

    try {
      if (intent === 'login') {
        await startLogin();
        // startLogin() は window.location.assign で /oauth/authorize へ
        // 飛ばすので、ここから先のコードは実質的に実行されない。
      } else if (intent === 'signup') {
        await prepareSignup();
      } else {
        await prepareLoginEmail();
      }
    } catch (e) {
      fatal(e);
    }
  });

  // ── signup: コード → 証明 → 作成 ──────────────────────────────────

  async function prepareSignup() {
    const draft = loadSignupDraft();
    if (!draft || !draft.email) throw new Error('no_draft');
    email = draft.email;

    // 20 分以内に取った証明が残っていれば、コードの段を飛ばす
    // (作成だけ失敗して戻ってきた人の打ち直しを無くす)。
    if (draft.email_proof) {
      await createAccount(draft.email_proof);
      return;
    }

    // 送信失敗(使われているアドレス等)は fatal にせず、コードの段の
    // 上にことばで置く ─ フォームへの戻り道がそこに見えている。
    try {
      await sendCode();
    } catch (e) {
      stepFail(e);
    }

    phase = 'code';
  }

  async function sendCode(force = false) {
    const kind = intent === 'signup' ? 'signup' : 'login';

    if (!force && recentlySent(kind, email)) {
      stepNotice = $t('check.codePrevValid');
      return;
    }

    if (intent === 'signup') {
      await requestSignupEmailCode(email);
    } else {
      await requestEmailLoginCode(email);
    }

    markSent(kind, email);
    stepNotice = $t('check.codeSentTo', { email });
  }

  async function resend() {
    if (busy) return;
    busy = true;
    stepError = null;
    try {
      await sendCode(true);
    } catch (e) {
      stepFail(e);
    } finally {
      busy = false;
    }
  }

  async function confirmCode() {
    if (busy) return;
    busy = true;
    stepError = null;
    try {
      if (intent === 'signup') {
        const proof = await confirmSignupEmailCode(email, code);
        const draft = loadSignupDraft();
        if (!draft) throw new Error('no_draft');
        // 作成が転んでも 20 分は打ち直し不要なように、証明を下書きへ。
        saveSignupDraft({ ...draft, email_proof: proof });
        await createAccount(proof);
      } else {
        const result = await loginWithEmailCode(email, code, addMode);
        if ('second_factor' in result) {
          pending = result.pending;
          totpCode = '';
          phase = 'totp';
        } else {
          await finishLogin();
        }
      }
    } catch (e) {
      if (phase === 'code') {
        stepFail(e);
      } else {
        fatal(e);
      }
    } finally {
      busy = false;
    }
  }

  async function createAccount(proof: string) {
    phase = 'working';
    const draft = loadSignupDraft();
    if (!draft) throw new Error('no_draft');

    const payload = {
      username: draft.username,
      invite_code: draft.invite_code,
      email_proof: proof,
      ...(draft.password ? { password: draft.password } : {})
    };

    // API call の直前に sessionStorage から password だけ消す。
    // 成功でも失敗でも、もう password はそこに無い ─ docs:
    // clearSignupPassword。証明は秘密ではない(20分の通行証)。
    clearSignupPassword();

    try {
      await signup(payload);
    } catch (e) {
      // 証明が古かったときだけ、コードの段からやり直せる。
      if (e instanceof Error && e.message === 'email_proof_invalid') {
        const d = loadSignupDraft();
        if (d) saveSignupDraft({ ...d, email_proof: undefined });
        stepError = $t('check.err.email_proof_invalid');
        await sendCode(true).catch(stepFail);
        phase = 'code';
        return;
      }
      throw e;
    }

    // 加入直後に first-party セッション(cookie)を立てる ─ メール加入を、
    // パスワードログインと同じ地位に。これで settings の管理面(パスキー・
    // 2FA・メール変更、どれも session cookie 専用)が、二度目のログイン
    // 無しでそのまま開ける。proof は本人が今証明したメールボックスの通行証。
    try {
      await establishSignupSession(proof);
    } catch {
      /* best-effort: 失敗しても、その画面に来たときメールの道で入りなおせる */
    }

    clearSignupDraft();
    sessionStorage.removeItem(SENT_KEY);
    sessionStorage.removeItem(RELOADED_KEY);
    await goto('/timeline');
  }

  // ── login-email: コード → cookie (→ totp) → OAuth ─────────────────

  async function prepareLoginEmail() {
    const saved = loadLoginEmail();
    if (!saved) {
      error = $t('check.noLoginEmail');
      phase = 'error';
      return;
    }
    email = saved;

    try {
      await sendCode();
    } catch (e) {
      stepFail(e);
    }

    phase = 'code';
  }

  async function submitTotpCode() {
    if (busy) return;
    busy = true;
    stepError = null;
    try {
      await submitTotp(pending, totpCode, addMode);
      await finishLogin();
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'pending') {
        // pending(5分)切れ。コードの段からやり直し。
        stepError = $t('login.totpExpired');
        phase = 'code';
        code = '';
      } else if (msg === 'rate_limited') {
        stepError = $t('login.rateLimited');
      } else {
        stepError = $t('login.totpFailed');
      }
    } finally {
      busy = false;
    }
  }

  async function finishLogin() {
    phase = 'working';
    clearLoginEmail();
    sessionStorage.removeItem(SENT_KEY);
    sessionStorage.removeItem(RELOADED_KEY);

    // /oauth/authorize から弾かれて来ていた人は元の authorize URL へ、
    // そうでなければここから OAuth コードフローを始める(PoW は済み)。
    if (next && next.startsWith('/oauth/')) {
      window.location.assign(next);
    } else {
      await startLogin();
    }
  }

  function retry() {
    window.location.reload();
  }
</script>

{#if phase === 'working'}
  <section class="hero">
    <h1>
      {#if intent === 'signup'}
        {$t('check.creatingAccount')}
      {:else if intent === 'login' || intent === 'login-email'}
        {$t('check.guidingLogin')}
      {:else}
        {$t('check.pleaseWaitTitle')}
      {/if}
    </h1>
  </section>
  <p class="loading">{$t('check.pleaseWait')}</p>
{:else if phase === 'code'}
  <section class="hero">
    <h1>{$t('check.codeTitle')}</h1>
    {#if stepNotice}<p class="tagline">{stepNotice}</p>{/if}
  </section>

  {#if stepError}
    <p class="error">{stepError}</p>
  {/if}

  <form
    class="form stack"
    onsubmit={(e) => {
      e.preventDefault();
      void confirmCode();
    }}
  >
    <label class="stack-tight">
      <span>{$t('login.code')}</span>
      <input
        type="text"
        bind:value={code}
        inputmode="numeric"
        autocomplete="one-time-code"
        pattern="[0-9]{'{6}'}"
        required
      />
    </label>
    <button type="submit" class="btn px-6 py-2" disabled={busy}>{$t('security.confirm')}</button>
    <button type="button" class="chip" disabled={busy} onclick={() => void resend()}
      >{$t('login.sendAgain')}</button
    >
  </form>

  <p class="prose-small">
    {#if intent === 'signup'}
      <a href="/signup">{$t('check.signupDraftKeptLink')}</a>
    {:else}
      <a href="/login">{$t('check.backToLogin')}</a>
    {/if}
  </p>
{:else if phase === 'totp'}
  <section class="hero">
    <h1>{$t('login.totpTitle')}</h1>
    <p class="tagline">{$t('login.totpHelp')}</p>
  </section>

  {#if stepError}
    <p class="error">{stepError}</p>
  {/if}

  <form
    class="form stack"
    onsubmit={(e) => {
      e.preventDefault();
      void submitTotpCode();
    }}
  >
    <label class="stack-tight">
      <span>{$t('login.code')}</span>
      <input
        type="text"
        bind:value={totpCode}
        inputmode="numeric"
        autocomplete="one-time-code"
        pattern="[0-9]{'{6}'}"
        required
      />
    </label>
    <button type="submit" class="btn px-6 py-2" disabled={busy}>{$t('login.submit')}</button>
  </form>
{:else if phase === 'error'}
  <section class="hero">
    <h1>{$t('check.failedTitle')}</h1>
  </section>
  <p class="error">{error}</p>
  <div class="stack">
    <button class="lane-door" onclick={retry} style="max-width: 16rem;">
      <h3>{$t('check.retry')}</h3>
    </button>
    {#if intent === 'signup'}
      <p class="prose-small">
        {$t('check.signupDraftKeptPre')}<a href="/signup">{$t('check.signupDraftKeptLink')}</a>{$t('check.signupDraftKeptPost')}
      </p>
    {:else if intent === 'login-email'}
      <p class="prose-small"><a href="/login">{$t('check.backToLogin')}</a></p>
    {:else}
      <p class="prose-small"><a href="/">{$t('common.backToTop')}</a></p>
    {/if}
  </div>
{/if}
