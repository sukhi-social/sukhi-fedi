<script lang="ts">
  import { goto } from '$app/navigation';
  import {
    requestSignupEmailCode,
    confirmSignupEmailCode,
    signup,
    setWarmthNote,
    isLoggedIn
  } from '$lib/auth';
  import { t } from '$lib/i18n.svelte';
  import Hinata from '$lib/Hinata.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  let phase = $state<'form' | 'code' | 'warmth' | 'working'>('form');

  let username = $state('');
  let email = $state('');
  let password = $state('');
  let code = $state('');
  let warmth = $state('');

  let token = $state('');

  let error = $state<string | null>(null);
  let notice = $state<string | null>(null);
  let busy = $state(false);

  if (isLoggedIn()) void goto('/');

  async function sendCode(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = null;
    try {
      await requestSignupEmailCode(email);
      notice = t().signup.codeSent(email);
      phase = 'code';
    } catch (e) {
      error = t().signup.errorSendFailed;
    } finally {
      busy = false;
    }
  }

  async function confirmAndCreate(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = null;
    try {
      const proof = await confirmSignupEmailCode(email, code);
      phase = 'working';
      const created = await signup(username, proof, password || undefined);
      token = created.access_token;
      phase = 'warmth';
      busy = false;
    } catch (e) {
      busy = false;
      phase = 'code';
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'email_taken') error = t().signup.errorEmailTaken;
      else if (msg === 'email_proof_invalid') error = t().signup.errorCodeInvalid;
      else if (msg.includes('validation')) error = t().signup.errorValidation;
      else error = t().signup.errorGeneric;
    }
  }

  async function finish() {
    if (busy) return;
    busy = true;
    if (warmth.trim()) await setWarmthNote(token, warmth.trim());
    await goto('/');
  }
</script>

<PageHeader title={t().signup.title} />

{#if phase === 'form'}
  <Hinata>
    <p>{t().signup.welcome}</p>
    <p>{t().signup.intro}</p>
  </Hinata>

  <form class="card stack" onsubmit={sendCode}>
    <label>
      <span class="muted">{t().signup.handle}</span>
      <input
        type="text"
        value={username}
        oninput={(e) => (username = e.currentTarget.value.toLowerCase())}
        required
        pattern="[a-z0-9_]{'{1,30}'}"
        autocomplete="username"
      />
    </label>
    <label>
      <span class="muted">{t().signup.email}</span>
      <input type="email" bind:value={email} required autocomplete="email" />
      <span class="muted small">{t().signup.emailHint}</span>
    </label>
    <label>
      <span class="muted">{t().signup.password}</span>
      <input type="password" bind:value={password} autocomplete="new-password" minlength="8" />
    </label>
    <button class="btn" type="submit" disabled={busy}>{t().signup.sendCode}</button>
  </form>
{:else if phase === 'code'}
  <form class="card stack" onsubmit={confirmAndCreate}>
    {#if notice}<p class="muted">{notice}</p>{/if}
    <label>
      <span class="muted">{t().signup.code}</span>
      <input type="text" bind:value={code} required inputmode="numeric" pattern="[0-9]{'{6}'}" autofocus />
    </label>
    <button class="btn" type="submit" disabled={busy}>{t().signup.create}</button>
  </form>
{:else if phase === 'warmth'}
  <Hinata>
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
    <button class="btn" type="submit" disabled={busy}>{busy ? t().signup.finishing : t().signup.finish}</button>
  </form>
{:else}
  <p class="muted">{t().signup.creating}</p>
{/if}

{#if error}<p class="error">{error}</p>{/if}

{#if phase === 'form'}
  <p class="prose-small"><a href="/login">{t().signup.loginLink}</a></p>
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

  .small {
    font-size: 0.8rem;
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
