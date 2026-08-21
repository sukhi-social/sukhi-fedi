<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import {
    isLoggedIn,
    loginWithPassword,
    loginWithEmailCode,
    requestEmailLoginCode,
    startLogin
  } from '$lib/auth';

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
      error = '入れませんでした';
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
      error = e instanceof Error && e.message === 'invalid' ? '名前か合言葉が違います' : '入れませんでした';
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
      notice = `${email} にコードを送りました`;
      phase = 'code';
    } catch {
      error = '送れませんでした';
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
      error = 'コードが違うか、古くなっています';
      busy = false;
    }
  }
</script>

<h1>入る</h1>

<div class="tabs">
  <button
    class="tab"
    class:active={method === 'email'}
    type="button"
    onclick={() => {
      method = 'email';
      phase = 'first';
      error = null;
    }}>メールのコード</button
  >
  <button
    class="tab"
    class:active={method === 'password'}
    type="button"
    onclick={() => {
      method = 'password';
      error = null;
    }}>合言葉</button
  >
</div>

{#if method === 'password'}
  <form class="card stack" onsubmit={submitPassword}>
    <label>
      <span class="muted">@ハンドル</span>
      <input type="text" bind:value={username} required autocomplete="username" />
    </label>
    <label>
      <span class="muted">合言葉</span>
      <input type="password" bind:value={password} required autocomplete="current-password" />
    </label>
    <button class="btn" type="submit" disabled={busy}>入る</button>
  </form>
{:else if phase === 'first'}
  <form class="card stack" onsubmit={sendCode}>
    <label>
      <span class="muted">メールアドレス</span>
      <input type="email" bind:value={email} required autocomplete="email" />
    </label>
    <button class="btn" type="submit" disabled={busy}>コードを送る</button>
  </form>
{:else}
  <form class="card stack" onsubmit={submitCode}>
    {#if notice}<p class="muted">{notice}</p>{/if}
    <label>
      <span class="muted">6桁のコード</span>
      <input type="text" bind:value={code} required inputmode="numeric" pattern="[0-9]{'{6}'}" autofocus />
    </label>
    <button class="btn" type="submit" disabled={busy}>入る</button>
  </form>
{/if}

{#if error}<p class="error">{error}</p>{/if}

<p class="prose-small"><a href="/signup">はじめての方はこちら</a></p>

<style>
  h1 {
    font-size: 1.4rem;
    margin: 0 0 1.25rem;
  }

  .tabs {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 1rem;
  }

  .tab {
    font-family: var(--font-round);
    font-weight: 700;
    background: transparent;
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 0.4rem 1rem;
    cursor: pointer;
  }

  .tab.active {
    background: var(--sun-soft);
    border-color: var(--sun);
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
