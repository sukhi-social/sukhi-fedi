<script lang="ts">
  // 店先。ここでは何も起こらない ── 打ったものを下書きとして置いて、
  // 関所(/check)へ渡すだけ。コードの送信も、アカウントを作るのも、
  // 向こう側で。Anubis を通れた人の手でだけ、それが起こるように。
  import { goto } from '$app/navigation';
  import { saveSignupDraft, loadSignupDraft, goToCheck } from '$lib/auth';
  import { signedIn } from '$lib/api';
  import { t, getLang } from '$lib/i18n.svelte';
  import Hinata from '$lib/Hinata.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  let username = $state('');
  let email = $state('');
  let password = $state('');
  let agreed = $state(false);
  let busy = $state(false);

  // 利用規約・プライバシーは、どちらも signup=true(下に「読みました」で
  // /signup に戻れる)へ。sukhi-fedi 本体の signup ページと同じ型 ──
  // 誘いの一文と、実際に作るボタンの脇の同意チェック、両方に置く。
  const termsHref = $derived(getLang() === 'ko' ? '/terms?signup=true&lang=ko' : '/terms?signup=true');
  const privacyHref = $derived(getLang() === 'ko' ? '/privacy?signup=true&lang=ko' : '/privacy?signup=true');
  const termsAnchor = $derived(`<a href="${termsHref}">${t().footer.terms}</a>`);
  const privacyAnchor = $derived(`<a href="${privacyHref}">${t().footer.privacy}</a>`);

  if (signedIn()) void goto('/');

  // 関所で転んで戻ってきた人に、打ち直させない。合言葉だけは戻らない
  // ── API を呼ぶ直前に落としているので(auth.ts の clearSignupPassword)。
  const draft = loadSignupDraft();
  if (draft) {
    username = draft.username;
    email = draft.email;
  }

  function toCheck(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    saveSignupDraft({ username, email, password: password || undefined });
    goToCheck('signup');
  }
</script>

<PageHeader title={t().signup.title} />

<Hinata src="/hinata-signup.png" side="right" big scale={1.5} inline>
  <p>{t().signup.welcome}</p>
  <p>{t().signup.intro}</p>
</Hinata>

<p class="read-first">{@html t().signup.readFirst(termsAnchor)}</p>

<form class="card stack" onsubmit={toCheck}>
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

<p class="prose-small"><a href="/login">{t().signup.loginLink}</a></p>
<p class="prose-small"><a href="/hello">{t().signup.backToHello}</a></p>

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
