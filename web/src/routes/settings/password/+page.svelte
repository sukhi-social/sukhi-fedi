<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { isLoggedIn, clearToken, changePassword, fetchAuthState } from '#lib/auth.js';
  import { verifyCredentials } from '#lib/api.js';
  import { t } from '#lib/i18n.js';

  // あいことばはレガシー・任意。まだ持っていない人がここに来たら
  // 「設定する」モード(いまの合言葉は要らない・セッションも生きた
  // まま)、持っている人は従来の「変える」モード(全セッション失効)。
  let username = $state('');
  let hasPassword = $state(true);
  let current = $state('');
  let nextPw = $state('');
  let confirm = $state('');
  let error = $state<string | null>(null);
  let submitting = $state(false);
  let done = $state<'changed' | 'set' | null>(null);

  onMount(async () => {
    if (!isLoggedIn()) {
      void goto('/');
      return;
    }
    // tagline の @id と、初回設定かどうか。読めなくても進められる
    // (サーバが正しい側の判定を持っている)。
    try {
      const me = await verifyCredentials();
      username = me.username ?? me.acct ?? '';
    } catch {
      /* tagline は空のままでよい */
    }
    try {
      const s = await fetchAuthState();
      if (s) hasPassword = s.has_password;
    } catch {
      /* 変更モード表示のまま */
    }
  });

  async function submit() {
    if (submitting) return;
    if (nextPw !== confirm) {
      error = $t('password.errMismatch');
      return;
    }
    submitting = true;
    error = null;
    try {
      const { initial } = await changePassword(current, nextPw, confirm);
      if (initial) {
        // 初回設定: セッションは生きたまま。トークンもそのまま。
        done = 'set';
      } else {
        // 変更: サーバが全セッションを失効させる。手元の OAuth
        // トークンももう用済みなので落として、入りなおしてもらう。
        clearToken();
        done = 'changed';
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      error =
        msg === 'current'
          ? $t('password.errCurrent')
          : msg === 'mismatch'
            ? $t('password.errMismatch')
            : msg === 'short'
              ? $t('password.errShort')
              : msg === 'unauthorized'
                ? $t('password.errAuth')
                : $t('password.failed');
      submitting = false;
    }
  }
</script>

{#if done === 'changed'}
  <section class="hero">
    <h1>{$t('password.doneTitle')}</h1>
  </section>
  <p class="notice">{$t('password.doneNotice')}</p>
  <p><a class="chip" href="/login">{$t('login.title')}</a></p>
{:else if done === 'set'}
  <section class="hero">
    <h1>{$t('password.setDoneTitle')}</h1>
  </section>
  <p class="notice">{$t('password.setDoneNotice')}</p>
  <p><a class="chip" href="/settings/security">{$t('security.title')}</a></p>
{:else}
  <section class="hero">
    <h1>{hasPassword ? $t('password.title') : $t('password.setTitle')}</h1>
    {#if username}<p class="tagline">{$t('password.tagline', { username })}</p>{/if}
  </section>

  {#if !hasPassword}
    <p class="prose-small">{$t('password.setHelp')}</p>
  {/if}

  {#if error}
    <p class="error">{error}</p>
  {/if}

  <form
    class="form stack"
    onsubmit={(e) => {
      e.preventDefault();
      void submit();
    }}
  >
    {#if hasPassword}
      <label class="stack-tight">
        <span>{$t('password.current')}</span>
        <input type="password" bind:value={current} autocomplete="current-password" required />
      </label>
    {/if}
    <label class="stack-tight">
      <span>{$t('password.new')}</span>
      <input type="password" bind:value={nextPw} autocomplete="new-password" minlength="8" required />
    </label>
    <label class="stack-tight">
      <span>{$t('password.confirm')}</span>
      <input
        type="password"
        bind:value={confirm}
        autocomplete="new-password"
        minlength="8"
        required
      />
    </label>
    <button type="submit" class="btn px-6 py-2" disabled={submitting}>
      {hasPassword ? $t('password.submit') : $t('password.setSubmit')}
    </button>
  </form>

  <p class="prose-small"><a href="/settings/security">{$t('security.backToSettings')}</a></p>
{/if}
