<script lang="ts">
  import { goto } from '$app/navigation';
  import {
    requestSignupEmailCode,
    confirmSignupEmailCode,
    signup,
    setWarmthNote,
    isLoggedIn
  } from '$lib/auth';
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
      notice = `${email} にコードを送りました`;
      phase = 'code';
    } catch (e) {
      error = 'コードを送れませんでした';
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
      const t = await signup(username, proof, password || undefined);
      token = t.access_token;
      phase = 'warmth';
      busy = false;
    } catch (e) {
      busy = false;
      phase = 'code';
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'email_taken') error = 'そのメールアドレスは、もう使われています';
      else if (msg === 'email_proof_invalid') error = 'コードが古いか、違っています';
      else if (msg.includes('validation')) error = 'ユーザー名か、コードを見直してください';
      else error = '作れませんでした';
    }
  }

  async function finish() {
    if (busy) return;
    busy = true;
    if (warmth.trim()) await setWarmthNote(token, warmth.trim());
    await goto('/');
  }
</script>

<PageHeader title="はじめる" />

{#if phase === 'form'}
  <Hinata>
    <p>ようこそ。ひなたです。</p>
    <p>ここで、あなたのことを少し教えてください。</p>
  </Hinata>

  <form class="card stack" onsubmit={sendCode}>
    <label>
      <span class="muted">@ハンドル(英小文字・数字・_、あとから変えられません)</span>
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
      <span class="muted">メールアドレス</span>
      <input type="email" bind:value={email} required autocomplete="email" />
      <span class="muted small">アカウントをなくしたとき、ここから帰ってこられます。</span>
    </label>
    <label>
      <span class="muted">合言葉(なくてもいい ── メールのコードだけで入れます)</span>
      <input type="password" bind:value={password} autocomplete="new-password" minlength="8" />
    </label>
    <button class="btn" type="submit" disabled={busy}>コードを送る</button>
  </form>
{:else if phase === 'code'}
  <form class="card stack" onsubmit={confirmAndCreate}>
    {#if notice}<p class="muted">{notice}</p>{/if}
    <label>
      <span class="muted">6桁のコード</span>
      <input type="text" bind:value={code} required inputmode="numeric" pattern="[0-9]{'{6}'}" autofocus />
    </label>
    <button class="btn" type="submit" disabled={busy}>つくる</button>
  </form>
{:else if phase === 'warmth'}
  <Hinata>
    <p>さいごに。</p>
    <p>
      ひなたは、みんなに「あたたかい」ことを聞いています。<br />
      あたたかい場所がいいと、信じているから。
    </p>
    <p>あなたにとって、今、あたたかいと感じるものは何ですか?</p>
  </Hinata>

  <form
    class="card stack"
    onsubmit={(e) => {
      e.preventDefault();
      void finish();
    }}
  >
    <label>
      <span class="muted">もしよければ、一言でも、どうぞ。</span>
      <input type="text" bind:value={warmth} maxlength="140" placeholder="こたえなくても、いいです" />
    </label>
    <button class="btn" type="submit" disabled={busy}>{busy ? 'すすんでいます…' : 'ナタデコへ'}</button>
  </form>
{:else}
  <p class="muted">つくっています…</p>
{/if}

{#if error}<p class="error">{error}</p>{/if}

{#if phase === 'form'}
  <p class="prose-small"><a href="/login">もうアカウントがある方はこちら</a></p>
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
