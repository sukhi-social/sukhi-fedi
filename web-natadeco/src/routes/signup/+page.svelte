<script lang="ts">
  import { goto } from '$app/navigation';
  import {
    requestSignupEmailCode,
    confirmSignupEmailCode,
    signup,
    setWarmthNote,
    isLoggedIn
  } from '$lib/auth';
  import { t, getLang } from '$lib/i18n.svelte';
  import Hinata from '$lib/Hinata.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  let phase = $state<'form' | 'code' | 'warmth' | 'working'>('form');

  let username = $state('');
  let email = $state('');
  let password = $state('');
  let code = $state('');
  let warmth = $state('');
  let agreed = $state(false);

  // 利用規約・プライバシーは、どちらも signup=true(下に「読みました」で
  // /signup に戻れる)へ。sukhi-fedi 本体の signup ページと同じ型 ──
  // 誘いの一文と、実際に作るボタンの脇の同意チェック、両方に置く。
  const termsHref = $derived(getLang() === 'ko' ? '/terms?signup=true&lang=ko' : '/terms?signup=true');
  const privacyHref = $derived(getLang() === 'ko' ? '/privacy?signup=true&lang=ko' : '/privacy?signup=true');
  const termsAnchor = $derived(`<a href="${termsHref}">${t().footer.terms}</a>`);
  const privacyAnchor = $derived(`<a href="${privacyHref}">${t().footer.privacy}</a>`);

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
  <Hinata src="/hinata-signup.png" side="right" big scale={1.5} inline>
    <p>{t().signup.welcome}</p>
    <p>{t().signup.intro}</p>
  </Hinata>

  <p class="read-first">{@html t().signup.readFirst(termsAnchor)}</p>

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
    <label class="agree">
      <input type="checkbox" bind:checked={agreed} required />
      <span>{@html t().signup.agree(termsAnchor, privacyAnchor)}</span>
    </label>
    <button class="btn" type="submit" disabled={busy || !agreed}>{t().signup.sendCode}</button>
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
    <button class="btn" type="submit" disabled={busy}>{busy ? t().signup.finishing : t().signup.finish}</button>
  </form>
{:else}
  <p class="muted">{t().signup.creating}</p>
{/if}

{#if error}<p class="error">{error}</p>{/if}

{#if phase === 'form'}
  <p class="prose-small"><a href="/login">{t().signup.loginLink}</a></p>
  <p class="prose-small"><a href="/hello">{t().signup.backToHello}</a></p>
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

  /* いきなり規約に飛ばさない、はじめの誘い。sukhi-fedi 本体の signup
     ページと同じ、やわらかい囲み。 */
  .read-first {
    max-width: 24rem;
    margin: 0 0 1rem;
    padding: 0.6rem 0.9rem;
    background: var(--sun-soft);
    border-radius: var(--radius);
    font-size: 0.9rem;
    line-height: 1.7;
  }

  /* 同意チェック ── 箱と文を横に、文頭にそろえる。 */
  .agree {
    display: flex;
    align-items: flex-start;
    gap: 0.5rem;
    font-size: 0.85rem;
    line-height: 1.5;
  }

  .agree input[type='checkbox'] {
    margin-top: 0.2rem;
    flex: none;
    width: auto;
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

  /* 行き先が二つ並ぶので、指の当たる範囲を広げる(前は 16px の行が
     9px しか離れていなかった)。段落を分けて、あいだも空ける。 */
  .prose-small a {
    display: inline-block;
    padding: 0.45rem 0;
  }
</style>
