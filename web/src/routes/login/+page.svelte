<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { page } from '$app/stores';
  import {
    goToCheck,
    isLoggedIn,
    loginWithPassword,
    loginWithPasskey,
    saveLoginEmail,
    submitTotp,
    type FirstFactorResult
  } from '$lib/auth';
  import { passkeySupported } from '$lib/webauthn';
  import { t } from '$lib/i18n';
  import LangSwitch from '$lib/components/LangSwitch.svelte';

  // 入りかたは二つから選べる: (確認済みの)メールに届くコード、または
  // パスワード。メールが既定で先頭 ─ 覚えるものが少ない道を正面に。
  // メールの道はコードの送信も入力も /check(Anubis の通り道)の上で
  // 行うので、このページからメールは出ない。パスワードの道で
  // アプリ 2FA を有効にしている人は、ここで totp の段が出る。
  let method = $state<'password' | 'email'>('email');
  let phase = $state<'first' | 'totp'>('first');

  let username = $state('');
  let password = $state('');

  let email = $state('');

  let pending = $state('');
  let totpCode = $state('');

  let error = $state<string | null>(null);
  let submitting = $state(false);
  let canPasskey = $state(false);

  // /oauth/authorize から未ログインで弾かれてきたときは ?next に元の
  // authorize URL が入っている。ホームの「入る」から来たときは next が
  // 無いので、Anubis の通り道 /check?intent=login を既定にする。
  let next = $derived.by(() => {
    const n = $page.url.searchParams.get('next');
    return n && n.startsWith('/') ? n : '/check?intent=login';
  });

  // startAddAccount() 発の「追加」入り口(マルチアカウント)。今すでに
  // ログイン済みでも弾かない ─ 別の資格情報を入れてもらうのが目的な
  // ので。今のところパスワードの道だけ繋がっている(メール・パスキーは
  // まだ)。
  let addMode = $derived($page.url.searchParams.get('mode') === 'add');

  onMount(() => {
    if (isLoggedIn() && !addMode) {
      void goto('/timeline');
      return;
    }
    if (addMode) method = 'password';
    canPasskey = passkeySupported();
  });

  // 一段目が通ったあとの分岐。cookie が立ったなら next(=/check か
  // /oauth/authorize)へフルリロードで渡す ─ /check は Anubis の
  // challenge を、authorize はサーバ描画を通す必要があるから SPA
  // ナビでは抜けられない。2FA の人は totp の段へ。
  function proceed(result: FirstFactorResult) {
    if ('second_factor' in result) {
      pending = result.pending;
      totpCode = '';
      error = null;
      phase = 'totp';
    } else {
      window.location.assign(next);
    }
  }

  async function submitPassword() {
    if (submitting) return;
    submitting = true;
    error = null;
    try {
      proceed(await loginWithPassword(username, password, addMode));
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      error = msg === 'invalid' ? $t('login.invalid') : $t('login.failed');
    } finally {
      submitting = false;
    }
  }

  // メールの道: アドレスを持って /check へ。PoW のあと、/check が
  // コードを送って・聞いて・cookie まで面倒を見る。oauth authorize
  // から弾かれて来た人は、その戻り先(?next)も一緒に持っていく。
  function goEmailCheck() {
    saveLoginEmail(email);
    const raw = $page.url.searchParams.get('next');
    goToCheck('login-email', raw && raw.startsWith('/') ? raw : undefined);
  }

  async function submitTotpCode() {
    if (submitting) return;
    submitting = true;
    error = null;
    try {
      await submitTotp(pending, totpCode, addMode);
      window.location.assign(next);
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'pending') {
        // pending トークン(5分)が切れた。一段目からやり直し。
        phase = 'first';
        error = $t('login.totpExpired');
      } else if (msg === 'rate_limited') {
        error = $t('login.rateLimited');
      } else {
        error = $t('login.totpFailed');
      }
    } finally {
      submitting = false;
    }
  }

  async function passkey() {
    if (submitting) return;
    submitting = true;
    error = null;
    try {
      await loginWithPasskey();
      window.location.assign(next);
    } catch (e) {
      // 認証器のダイアログを自分で閉じたときは、何も言わない。
      if (!(e instanceof DOMException && e.name === 'NotAllowedError')) {
        error = $t('login.passkeyFailed');
      }
    } finally {
      submitting = false;
    }
  }
</script>

<div class="measure stack">
  <section class="hero">
    <h1>{addMode ? $t('login.addTitle') : $t('login.title')}</h1>
    <p class="tagline">{addMode ? $t('login.addTagline') : $t('login.tagline')}</p>
  </section>

  {#if error}
    <p class="error">{error}</p>
  {/if}

  {#if phase === 'totp'}
    <section class="section">
      <h2 style="font-size: var(--text-base);">{$t('login.totpTitle')}</h2>
      <p class="prose-small">{$t('login.totpHelp')}</p>
    </section>

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
      <button type="submit" class="btn px-6 py-2" disabled={submitting}>{$t('login.submit')}</button>
    </form>
  {:else}
    {#if !addMode}
      <div class="method-switch" role="tablist" aria-label={$t('login.methodLabel')}>
        <button
          type="button"
          class="chip"
          role="tab"
          aria-selected={method === 'email'}
          onclick={() => {
            method = 'email';
            error = null;
          }}>{$t('login.methodEmail')}</button
        >
        <button
          type="button"
          class="chip"
          role="tab"
          aria-selected={method === 'password'}
          onclick={() => {
            method = 'password';
            error = null;
          }}>{$t('login.methodPassword')}</button
        >
      </div>
    {/if}

    {#if method === 'password'}
      <form
        class="form stack"
        onsubmit={(e) => {
          e.preventDefault();
          void submitPassword();
        }}
      >
        <label class="stack-tight">
          <span>{$t('login.handle')}</span>
          <input
            type="text"
            bind:value={username}
            autocomplete="username"
            autocapitalize="none"
            autocorrect="off"
            spellcheck="false"
            required
          />
        </label>

        <label class="stack-tight">
          <span>{$t('login.password')}</span>
          <input type="password" bind:value={password} autocomplete="current-password" required />
        </label>

        <button type="submit" class="btn px-6 py-2" disabled={submitting}>{$t('login.submit')}</button>
      </form>
    {:else}
      <form
        class="form stack"
        onsubmit={(e) => {
          e.preventDefault();
          goEmailCheck();
        }}
      >
        <label class="stack-tight">
          <span>{$t('login.email')}</span>
          <input
            type="email"
            bind:value={email}
            autocomplete="email"
            autocapitalize="none"
            spellcheck="false"
            required
          />
          <span class="help">{$t('login.emailHelp')}</span>
        </label>

        <button type="submit" class="btn px-6 py-2" disabled={submitting}
          >{$t('login.sendCode')}</button
        >
      </form>
    {/if}

    {#if canPasskey && !addMode}
      <p class="prose-small" style="margin-top: var(--space-4);">
        <button type="button" class="chip" disabled={submitting} onclick={() => void passkey()}
          >{$t('login.passkey')}</button
        >
      </p>
    {/if}

    {#if addMode}
      <p class="prose-small"><a href="/timeline">{$t('common.backToTimeline')}</a></p>
    {:else}
      <p class="prose-small"><a href="/signup">{$t('login.toSignup')}</a></p>
      <p class="prose-small"><a href="/">{$t('signup.backToFront')}</a></p>
    {/if}
  {/if}

  <section class="section" style="text-align: center; margin-top: var(--space-5);">
    <LangSwitch />
  </section>
</div>

<style>
  .method-switch {
    display: flex;
    gap: var(--space-2);
    margin-bottom: var(--space-4);
  }
  .method-switch .chip[aria-selected='true'] {
    border-color: var(--color-text);
    font-weight: 600;
  }
</style>
