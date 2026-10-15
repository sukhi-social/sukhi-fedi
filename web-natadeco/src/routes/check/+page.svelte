<script lang="ts">
  // 共通の「通り道」。Anubis がこの path だけを CHALLENGE するので、
  // ここに来た時点で関所は通っている ── メールの 6 桁コードの送信も
  // 入力も、アカウントを作るのも、全部この上で起こる。
  //
  //   /check?intent=login        → (古い道。いまは cookie で入っているので、
  //                                行きたかった場所へ)
  //   /check?intent=signup       → コード送信 → 入力 → 証明 → 作成 →
  //                                パスキー → あたたかいこと → デコの一覧
  //   /check?intent=login-email  → コード送信 → 入力 → cookie → 行きたかった場所
  //
  // 店先(/login /signup)は素通しで、そこで打ったものは sessionStorage
  // に置いて渡ってくる。この順を逆にしない ── 先に API を叩いて後で
  // PoW、にすると、通れない人のアカウントが先に出来てしまう。
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    signup,
    startSignupSession,
    registerPasskey,
    setWarmthNote,
    loginWithEmailCode,
    requestEmailLoginCode,
    requestSignupEmailCode,
    confirmSignupEmailCode,
    loadSignupDraft,
    saveSignupDraft,
    clearSignupDraft,
    clearSignupPassword,
    loadLoginEmail,
    clearLoginEmail
  } from '#lib/auth.js';
  import { passkeySupported } from '#lib/webauthn.js';
  import { t } from '#lib/i18n.svelte.js';
  import Hinata from '#lib/Hinata.svelte';
  import PageHeader from '#lib/PageHeader.svelte';

  type Intent = 'login' | 'signup' | 'login-email';

  let phase = $state<'working' | 'code' | 'passkey' | 'warmth' | 'error'>('working');
  let intent = $state<Intent | null>(null);
  let error = $state<string | null>(null);

  let email = $state('');
  let code = $state('');
  let token = $state('');
  let warmth = $state('');
  let busy = $state(false);

  // その場で直せる失敗(コード違い・送れなかった)は、この段に留まる。
  let stepError = $state<string | null>(null);
  let stepNotice = $state<string | null>(null);
  let passkeyNotice = $state<string | null>(null);

  // 10 分以内に同じ宛先へ送っていたら、自動送信を黙って飛ばす ──
  // 読み直すたびに送ると、コードの有効期限より先にレート制限に当たる。
  // 前のコードは、まだそのまま使える。
  const SENT_KEY = 'nd.check_code_sent';

  function recentlySent(to: string): boolean {
    try {
      const raw = sessionStorage.getItem(SENT_KEY);
      if (!raw) return false;
      const v = JSON.parse(raw) as { to: string; at: number };
      return v.to === to && Date.now() - v.at < 10 * 60 * 1000;
    } catch {
      return false;
    }
  }

  // コードの段のことばは、来た道のことばを使う。
  const codeLabel = $derived(intent === 'signup' ? t().signup.code : t().login.code);
  const submitLabel = $derived(intent === 'signup' ? t().signup.create : t().login.submit);

  // ここから先へ進めない失敗。段の上で直せるものは stepFail のほうへ。
  function fatal(): void {
    error = intent === 'signup' ? t().signup.errorGeneric : t().login.errorGeneric;
    phase = 'error';
  }

  function stepFail(kind: 'send' | 'code'): void {
    stepError =
      kind === 'send'
        ? intent === 'signup'
          ? t().signup.errorSendFailed
          : t().login.errorSendFailed
        : intent === 'signup'
          ? t().signup.errorCodeInvalid
          : t().login.errorCodeInvalid;
  }

  onMount(async () => {
    const i = new URLSearchParams(window.location.search).get('intent');
    if (i !== 'login' && i !== 'signup' && i !== 'login-email') {
      error = t().check.unknownIntent;
      phase = 'error';
      return;
    }
    intent = i;

    try {
      if (intent === 'login') {
        goNext();
      } else if (intent === 'signup') {
        await prepareSignup();
      } else {
        await prepareLoginEmail();
      }
    } catch {
      fatal();
    }
  });

  // ── signup: コード → 証明 → 作成 ──────────────────────────────────

  async function prepareSignup() {
    const draft = loadSignupDraft();
    if (!draft?.email) {
      error = t().check.noDraft;
      phase = 'error';
      return;
    }
    email = draft.email;

    // 20 分以内に取った証明が残っていれば、コードの段は飛ばす
    // (作るところだけ転んで戻ってきた人に、打ち直させない)。
    if (draft.email_proof) {
      await createAccount(draft.email_proof);
      return;
    }

    // 送れなかったときも、この段に留まる ── 戻り道がここに見えている。
    try {
      await sendCode();
    } catch {
      stepFail('send');
    }
    phase = 'code';
  }

  async function sendCode(force = false) {
    if (!force && recentlySent(email)) {
      stepNotice = t().check.codePrevValid;
      return;
    }
    if (intent === 'signup') await requestSignupEmailCode(email);
    else await requestEmailLoginCode(email);

    sessionStorage.setItem(SENT_KEY, JSON.stringify({ to: email, at: Date.now() }));
    stepNotice = intent === 'signup' ? t().signup.codeSent(email) : t().login.codeSent(email);
  }

  async function resend() {
    if (busy) return;
    busy = true;
    stepError = null;
    try {
      await sendCode(true);
    } catch {
      stepFail('send');
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
        if (!draft) {
          error = t().check.noDraft;
          phase = 'error';
          return;
        }
        saveSignupDraft({ ...draft, email_proof: proof });
        await createAccount(proof);
      } else {
        await loginWithEmailCode(email, code);
        finishLogin();
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'email_taken') stepError = t().signup.errorEmailTaken;
      else if (phase === 'code') stepFail('code');
      else fatal();
    } finally {
      busy = false;
    }
  }

  async function createAccount(proof: string) {
    phase = 'working';
    const draft = loadSignupDraft();
    if (!draft) {
      error = t().check.noDraft;
      phase = 'error';
      return;
    }

    // API を呼ぶ直前に、合言葉だけ sessionStorage から落とす。
    // 成功でも失敗でも、ここから先そこに合言葉は無い。
    const password = draft.password;
    clearSignupPassword();

    try {
      const created = await signup(draft.username, proof, password || undefined);
      token = created.access_token;
    } catch (e) {
      // 証明が古かったときだけ、コードの段からやり直せる。
      if (e instanceof Error && e.message === 'email_proof_invalid') {
        const d = loadSignupDraft();
        if (d) saveSignupDraft({ ...d, email_proof: undefined });
        stepError = t().signup.errorCodeInvalid;
        code = '';
        await sendCode(true).catch(() => stepFail('send'));
        phase = 'code';
        return;
      }
      throw e;
    }

    // 加入直後に cookie を立てる。パスキーの登録口は cookie 専用なので、
    // 通らなかったらパスキーのおさそいは出さずに先へ ── 加入を止める
    // 理由には、ならないので。
    const session = await startSignupSession(proof);

    clearSignupDraft();
    sessionStorage.removeItem(SENT_KEY);
    phase = session && passkeySupported() ? 'passkey' : 'warmth';
  }

  async function addPasskey() {
    if (busy) return;
    busy = true;
    passkeyNotice = null;
    try {
      await registerPasskey('');
      phase = 'warmth';
    } catch (e) {
      // 途中でやめた人は、そのまま次へ ── ここで足踏みさせない。
      if (e instanceof DOMException && e.name === 'NotAllowedError') phase = 'warmth';
      else passkeyNotice = t().signup.passkeyFailed;
    } finally {
      busy = false;
    }
  }

  async function finish() {
    if (busy) return;
    busy = true;
    if (warmth.trim()) await setWarmthNote(token, warmth.trim());
    await goto('/');
  }

  // ── login-email: コード → cookie → OAuth ──────────────────────────

  async function prepareLoginEmail() {
    const saved = loadLoginEmail();
    if (!saved) {
      error = t().check.noDraft;
      phase = 'error';
      return;
    }
    email = saved;

    try {
      await sendCode();
    } catch {
      stepFail('send');
    }
    phase = 'code';
  }

  // /login が置いていった「入ったら戻る場所」へ。
  function goNext() {
    const next = sessionStorage.getItem('nd.next');
    sessionStorage.removeItem('nd.next');
    void goto(next && next.startsWith('/') ? next : '/');
  }

  function finishLogin() {
    phase = 'working';
    clearLoginEmail();
    sessionStorage.removeItem(SENT_KEY);
    goNext();
  }
</script>

{#if phase === 'working'}
  <p class="muted">{intent === 'signup' ? t().signup.creating : t().check.guiding}</p>
{:else if phase === 'code'}
  <PageHeader title={t().check.codeTitle} />

  <form
    class="card stack"
    onsubmit={(e) => {
      e.preventDefault();
      void confirmCode();
    }}
  >
    {#if stepNotice}<p class="muted">{stepNotice}</p>{/if}
    <label>
      <span class="muted">{codeLabel}</span>
      <input
        type="text"
        bind:value={code}
        required
        inputmode="numeric"
        autocomplete="one-time-code"
        pattern="[0-9]{'{6}'}"
        autofocus
      />
    </label>
    <button class="btn" type="submit" disabled={busy}>{submitLabel}</button>
    <button class="later" type="button" disabled={busy} onclick={() => void resend()}>
      {t().check.resend}
    </button>
  </form>

  {#if stepError}<p class="error">{stepError}</p>{/if}

  <p class="prose-small">
    {#if intent === 'signup'}
      <a href="/signup">{t().check.backToSignup}</a>
    {:else}
      <a href="/login">{t().check.backToLogin}</a>
    {/if}
  </p>
{:else if phase === 'passkey'}
  <Hinata src="/hinata-signup.png" side="right" big scale={1.5} inline>
    <p>{t().signup.passkeyTitle}</p>
    <p>
      {t().signup.passkeyBody1}<br />
      {t().signup.passkeyBody2}
    </p>
  </Hinata>

  <div class="card stack">
    {#if passkeyNotice}<p class="muted">{passkeyNotice}</p>{/if}
    <button class="btn" type="button" disabled={busy} onclick={addPasskey}>
      {busy ? t().signup.passkeyAdding : t().signup.passkeyAdd}
    </button>
    <button class="later" type="button" onclick={() => (phase = 'warmth')}>
      {t().signup.passkeySkip}
    </button>
  </div>
{:else if phase === 'warmth'}
  <Hinata src="/hinata-signup.png" side="right" big scale={1.5} inline>
    <p>{t().signup.warmthTitle}</p>
    <p>
      {t().signup.warmthBody1}<br />
      {t().signup.warmthBody2}
    </p>
    <p>{t().signup.warmthQuestion}</p>
  </Hinata>

  <form
    class="card stack"
    onsubmit={(e) => {
      e.preventDefault();
      void finish();
    }}
  >
    <label>
      <span class="muted">{t().signup.warmthField}</span>
      <input type="text" bind:value={warmth} maxlength="140" placeholder={t().signup.warmthPlaceholder} />
    </label>
    <button class="btn" type="submit" disabled={busy}>
      {busy ? t().signup.finishing : t().signup.finish}
    </button>
  </form>
{:else}
  <PageHeader title={t().check.failedTitle} />
  <p class="error">{error}</p>
  <div class="stack">
    <button class="btn" type="button" onclick={() => window.location.reload()}>{t().check.retry}</button>
    <p class="prose-small">
      {#if intent === 'signup'}
        <a href="/signup">{t().check.backToSignup}</a>
      {:else if intent === 'login-email'}
        <a href="/login">{t().check.backToLogin}</a>
      {:else}
        <a href="/">{t().common.toDecoList}</a>
      {/if}
    </p>
  </div>
{/if}

<style>
  .stack {
    display: grid;
    gap: 0.85rem;
    max-width: 24rem;
  }

  label {
    display: grid;
    gap: 0.3rem;
  }

  /* 「もう一度送る」「あとで」は、押さなくていいものとして静かに。
     でもタップ領域は 44px(/signup の .later と同じ寸法)。 */
  .later {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 2.75rem;
    background: transparent;
    border: none;
    color: var(--ink-soft);
    font-size: 0.85rem;
    cursor: pointer;
  }

  .error {
    margin-top: 1rem;
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
  }

  .prose-small {
    margin-top: 1.25rem;
  }
</style>
