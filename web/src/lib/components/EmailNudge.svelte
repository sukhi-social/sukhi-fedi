<script lang="ts">
  // メールアドレスのお願いポップアップ。ログイン中で、確認済みの
  // メールが無い人にだけ、そっと出る。UpdateBanner と同じ、下に
  // 浮かぶ非モーダルのカード ─ 画面は塞がない。「あとで」で 3 日
  // 静かになる。
  //
  // 状態は /auth/state(bearer でも読める)で見る。変更系は session
  // cookie 専用なので、cookie が無い人(ずっと前にログインした人や、
  // 加入時の cookie 取りが失敗した人)には、入力欄ではなく
  // 「入りなおしてください」を出す。
  import { onMount } from 'svelte';
  import { afterNavigate } from '$app/navigation';
  import { page } from '$app/state';
  import { browser } from '$app/environment';
  import {
    isLoggedIn,
    fetchAuthState,
    requestEmailCode,
    confirmEmailCode,
    type AuthState
  } from '$lib/auth';
  import { t } from '$lib/i18n';

  const SNOOZE_KEY = 'sukhi.emailNudge.until';
  const SNOOZE_MS = 3 * 24 * 60 * 60 * 1000;

  // ログイン前後の導線と法的ページでは出さない。/settings/security に
  // 居る人には言うまでもない。
  const QUIET_PREFIXES = [
    '/login',
    '/signup',
    '/check',
    '/app/callback',
    '/privacy',
    '/terms',
    '/settings/security'
  ];

  let auth = $state<AuthState | null>(null);
  let show = $state(false);
  // 一度 token 付きで確かめたら、ナビゲーションのたびに再取得は
  // しない。加入・ログイン直後(SPA ナビで layout が残るケース)だけ
  // afterNavigate で拾い直す。
  let checkedWithToken = false;

  let quiet = $derived(
    page.url.pathname === '/' ||
      QUIET_PREFIXES.some((p) => page.url.pathname.startsWith(p))
  );

  function snoozed(): boolean {
    if (!browser) return true;
    const until = Number(localStorage.getItem(SNOOZE_KEY) ?? '0');
    return Date.now() < until;
  }

  async function decide() {
    if (!browser || !isLoggedIn() || snoozed()) return;
    checkedWithToken = true;
    try {
      const s = await fetchAuthState();
      if (s && !s.email_verified) {
        auth = s;
        emailInput = s.email ?? '';
        show = true;
      }
    } catch {
      // 読めなかったら、出さない。次の機会に。
    }
  }

  onMount(() => void decide());
  afterNavigate(() => {
    if (!checkedWithToken && isLoggedIn()) void decide();
  });

  function later() {
    if (browser) localStorage.setItem(SNOOZE_KEY, String(Date.now() + SNOOZE_MS));
    show = false;
  }

  // ── 中のちいさなフォーム ────────────────────────────────────────────
  let emailInput = $state('');
  let code = $state('');
  let codeSent = $state(false);
  let busy = $state(false);
  let error = $state<string | null>(null);
  let done = $state(false);

  async function send() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      await requestEmailCode(emailInput);
      codeSent = true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      error =
        msg === 'email'
          ? $t('security.emailInvalid')
          : msg === 'email_taken'
            ? $t('security.emailTaken')
            : msg === 'rate_limited'
              ? $t('login.rateLimited')
              : msg === 'unauthorized'
                ? $t('security.needRelogin')
                : $t('common.deliverFailed');
    } finally {
      busy = false;
    }
  }

  async function confirm() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      await confirmEmailCode(code);
      done = true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      error =
        msg === 'code'
          ? $t('security.codeWrong')
          : msg === 'expired'
            ? $t('security.codeExpired')
            : $t('common.deliverFailed');
    } finally {
      busy = false;
    }
  }
</script>

{#if show && !quiet}
  <aside class="email-nudge" role="status" aria-live="polite">
    {#if done}
      <p>{$t('nudge.thanks')}</p>
      <div class="actions">
        <button type="button" class="btn px-3 py-1" onclick={() => (show = false)}>{$t('nudge.close')}</button>
      </div>
    {:else}
      <p class="lead">
        {auth?.email ? $t('nudge.bodyUnverified') : $t('nudge.bodyNone')}
      </p>

      {#if auth && !auth.manageable}
        <p class="small">{$t('security.needRelogin')}</p>
        <div class="actions">
          <a class="btn px-3 py-1" href="/login">{$t('security.reloginLink')}</a>
          <button type="button" class="btn secondary px-3 py-1" onclick={later}>{$t('nudge.later')}</button>
        </div>
      {:else}
        <form
          class="nudge-form"
          onsubmit={(e) => {
            e.preventDefault();
            void (codeSent ? confirm() : send());
          }}
        >
          {#if codeSent}
            <p class="small">{$t('security.codeSent')}</p>
            <input
              type="text"
              bind:value={code}
              inputmode="numeric"
              autocomplete="one-time-code"
              placeholder={$t('login.code')}
              pattern="[0-9]{'{6}'}"
              required
            />
            <div class="actions">
              <button type="submit" class="btn px-3 py-1" disabled={busy}>{$t('security.confirm')}</button>
              <button type="button" class="btn secondary px-3 py-1" disabled={busy} onclick={() => void send()}
                >{$t('login.sendAgain')}</button
              >
            </div>
          {:else}
            <input
              type="email"
              bind:value={emailInput}
              autocomplete="email"
              placeholder={$t('signup.email')}
              required
            />
            <div class="actions">
              <button type="submit" class="btn px-3 py-1" disabled={busy}>{$t('login.sendCode')}</button>
              <button type="button" class="btn secondary px-3 py-1" onclick={later}>{$t('nudge.later')}</button>
            </div>
          {/if}
        </form>
        {#if error}
          <p class="small error-line">{error}</p>
        {/if}
      {/if}
    {/if}
  </aside>
{/if}

<style>
  /* 流れの中に置く。浮かせない ── 浮かせると、画面の下にあるものを
     そのぶん覆う。実際、タイムラインの下三分の一と、DM の composer が
     ずっと隠れていた。ここは催促であって警告ではないので、来たときに
     一度目に入って、読み進めれば流れて消える、くらいでいい。 */
  .email-nudge {
    max-width: 24rem;
    margin-inline: auto;
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius);
    font-size: var(--text-sm);
    display: grid;
    gap: var(--space-2);
  }

  .email-nudge p {
    margin: 0;
  }

  .lead {
    line-height: 1.6;
  }

  .small {
    color: var(--color-text-muted);
    font-size: 0.85em;
  }

  .error-line {
    color: var(--color-danger);
  }

  .nudge-form {
    display: grid;
    gap: var(--space-2);
  }

  .nudge-form input {
    font: inherit;
    padding: var(--space-1) var(--space-2);
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
    color: var(--color-text);
  }

  .actions {
    display: flex;
    gap: var(--space-2);
    flex-wrap: wrap;
  }
</style>
