<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import {
    isLoggedIn,
    loginWithPassword,
    loginWithEmailCode,
    loginWithPasskey,
    requestEmailLoginCode,
    startLogin
  } from '$lib/auth';
  import { passkeySupported } from '$lib/webauthn';
  import { t } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  // メールのコードを先頭に ── 合言葉を持たないアカウントもあるので。
  let method = $state<'email' | 'password'>('email');
  let phase = $state<'first' | 'code'>('first');

  let username = $state('');
  let password = $state('');
  let email = $state('');
  let code = $state('');

  let error = $state<string | null>(null);
  let notice = $state<string | null>(null);
  let busy = $state(false);

  // ブラウザに WebAuthn があるか。サーバ側ではいつも false になるので
  // ($effect の外だと SSG のビルド時に固まる)、載ってから見る。
  let canPasskey = $state(false);
  $effect(() => {
    canPasskey = passkeySupported();
  });

  // 「〇〇に書くには入って」から来た人を、入ったあと元の場所へ戻す。
  // OAuth の往復(→ /oauth/authorize → /app/callback)を挟むので、
  // ここでは sessionStorage に置いておく(callback 側が読む)。
  const next = page.url.searchParams.get('next');
  if (next && next.startsWith('/')) sessionStorage.setItem('nd.next', next);

  if (isLoggedIn()) void goto(next && next.startsWith('/') ? next : '/');

  async function finishLogin() {
    error = null;
    try {
      await startLogin();
    } catch {
      error = t().login.errorGeneric;
    }
  }

  async function submitPasskey() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      await loginWithPasskey();
      await finishLogin();
    } catch (e) {
      // 認証器のダイアログを自分で閉じたときは、何も言わない ──
      // 「やめた」に、エラーを返さない。
      if (!(e instanceof DOMException && e.name === 'NotAllowedError')) {
        error = t().login.passkeyFailed;
      }
    } finally {
      busy = false;
    }
  }

  async function submitPassword(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = null;
    try {
      await loginWithPassword(username, password);
      await finishLogin();
    } catch (e) {
      error = e instanceof Error && e.message === 'invalid' ? t().login.errorInvalid : t().login.errorGeneric;
    } finally {
      busy = false;
    }
  }

  async function sendCode(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = null;
    try {
      await requestEmailLoginCode(email);
      notice = t().login.codeSent(email);
      phase = 'code';
    } catch {
      error = t().login.errorSendFailed;
    } finally {
      busy = false;
    }
  }

  async function submitCode(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = null;
    try {
      await loginWithEmailCode(email, code);
      await finishLogin();
    } catch {
      error = t().login.errorCodeInvalid;
      busy = false;
    }
  }
</script>

<PageHeader title={t().login.title} />

{#if canPasskey}
  <div class="passkey">
    <button class="btn" type="button" disabled={busy} onclick={submitPasskey}>
      {t().login.passkey}
    </button>
  </div>
{/if}

<div class="tabs">
  <button
    class="tab"
    class:active={method === 'email'}
    type="button"
    onclick={() => {
      method = 'email';
      phase = 'first';
      error = null;
    }}>{t().login.tabEmail}</button
  >
  <button
    class="tab"
    class:active={method === 'password'}
    type="button"
    onclick={() => {
      method = 'password';
      error = null;
    }}>{t().login.tabPassword}</button
  >
</div>

{#if method === 'password'}
  <form class="card stack" onsubmit={submitPassword}>
    <label>
      <span class="muted">{t().login.handle}</span>
      <input type="text" bind:value={username} required autocomplete="username" />
    </label>
    <label>
      <span class="muted">{t().login.password}</span>
      <input type="password" bind:value={password} required autocomplete="current-password" />
    </label>
    <button class="btn" type="submit" disabled={busy}>{t().login.submit}</button>
  </form>
{:else if phase === 'first'}
  <form class="card stack" onsubmit={sendCode}>
    <label>
      <span class="muted">{t().login.email}</span>
      <input type="email" bind:value={email} required autocomplete="email" />
    </label>
    <button class="btn" type="submit" disabled={busy}>{t().login.sendCode}</button>
  </form>
{:else}
  <form class="card stack" onsubmit={submitCode}>
    {#if notice}<p class="muted">{notice}</p>{/if}
    <label>
      <span class="muted">{t().login.code}</span>
      <input type="text" bind:value={code} required inputmode="numeric" pattern="[0-9]{'{6}'}" autofocus />
    </label>
    <button class="btn" type="submit" disabled={busy}>{t().login.submit}</button>
  </form>
{/if}

{#if error}<p class="error">{error}</p>{/if}

<p class="prose-small"><a href="/hello">{t().login.signupLink}</a></p>

<style>

  /* 覚えるものが要らない道を、いちばん上に。下のタブ(メール/合言葉)は
     そのままの並びで残す ── パスキーを持っていない人の道が、この一段で
     遠くならないように。 */
  .passkey {
    margin-bottom: 1.25rem;
  }

  .tabs {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 1rem;
  }

  /* LangTabs と同じ寸法(タップ領域 44px 込み) ── 同じ役割(切り替え
     タブ)はどのページでも同じ見た目に。 */
  .tab {
    display: inline-flex;
    align-items: center;
    min-height: 2.75rem;
    font-family: var(--font-round);
    font-weight: 700;
    font-size: 0.85rem;
    background: transparent;
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 0.35rem 0.9rem;
    cursor: pointer;
    color: var(--ink-soft);
  }

  .tab.active {
    background: var(--sun-soft);
    border-color: var(--sun);
    color: var(--ink);
  }

  .stack {
    display: grid;
    gap: 0.85rem;
    max-width: 24rem;
  }

  label {
    display: grid;
    gap: 0.3rem;
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
