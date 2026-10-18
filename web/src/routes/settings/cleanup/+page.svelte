<script lang="ts">
  // 自分の古い投稿のお片づけ。ローカルにアーカイブ(行は残す)して、
  // Delete を連合する(相手にも忘れてもらう)。常時動くトグルではなく、
  // 「下見 → はっきり実行」の二段。数字は煽りではなく、消える前に
  // 正直に見せるためのもの。session cookie 専用(security ページと同じ)。
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    isLoggedIn,
    fetchAuthState,
    previewCleanup,
    executeCleanup,
    type AuthState,
    type Reauth,
    type CleanupPreview
  } from '#lib/auth.js';
  import ReauthField from '#lib/components/ReauthField.svelte';
  import { t } from '#lib/i18n.js';

  let auth = $state<AuthState | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);

  // 期間: 0 = ぜんぶ。それ以外は「N 日より古いもの」。
  let olderThanDays = $state(365);
  let preview = $state<CleanupPreview | null>(null);
  let done = $state<CleanupPreview | null>(null);
  let busy = $state(false);

  // 本人確認の入力。
  let password = $state('');
  let reauthCode = $state('');

  onMount(() => {
    if (!isLoggedIn()) {
      void goto('/');
      return;
    }
    void load();
  });

  async function load() {
    loading = true;
    error = null;
    try {
      auth = await fetchAuthState();
      if (!auth) {
        void goto('/');
        return;
      }
    } catch {
      error = $t('common.readFailed');
    } finally {
      loading = false;
    }
  }

  function reauthOf(): Reauth {
    return auth?.has_password ? { password } : { reauth_code: reauthCode };
  }

  function explain(e: unknown): string {
    const msg = e instanceof Error ? e.message : '';
    switch (msg) {
      case 'reauth':
        return auth?.has_password ? $t('security.wrongPassword') : $t('security.reauthFailed');
      case 'rate_limited':
        return $t('login.rateLimited');
      default:
        return $t('common.deliverFailed');
    }
  }

  async function doPreview() {
    if (busy) return;
    busy = true;
    error = null;
    done = null;
    try {
      preview = await previewCleanup(olderThanDays);
    } catch (e) {
      error = explain(e);
    } finally {
      busy = false;
    }
  }

  function cancelPreview() {
    preview = null;
    password = '';
    reauthCode = '';
    error = null;
  }

  async function doExecute() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      done = await executeCleanup(olderThanDays, reauthOf());
      preview = null;
      password = '';
      reauthCode = '';
    } catch (e) {
      error = explain(e);
    } finally {
      busy = false;
    }
  }
</script>

<header class="timeline page-head">
  <h1>{$t('cleanup.title')}</h1>
</header>

{#if loading}
  <p class="loading">{$t('common.loading')}</p>
{:else if error && !auth}
  <p class="error">{error}</p>
{:else if auth && !auth.manageable}
  <section class="timeline" style="margin-block: var(--space-4);">
    <p>{$t('security.needRelogin')}</p>
    <p class="prose-small"><a class="chip" href="/login">{$t('security.reloginLink')}</a></p>
  </section>
{:else if auth}
  <section class="timeline danger">
    <p class="prose-small">{$t('cleanup.intro')}</p>

    {#if done}
      <!-- すんだあと: 何件をお片づけにまわしたか、正直に。 -->
      <p>{$t('cleanup.startedPre')}{done.affected}{$t('cleanup.startedPost')}</p>
      <p class="prose-small">{$t('cleanup.startedHelp')}</p>
      <p>
        <button type="button" class="chip" onclick={() => (done = null)}>{$t('cleanup.again')}</button>
      </p>
    {:else if !preview}
      <!-- 下見の前: 期間を選んで「下見」。 -->
      <form
        class="form stack"
        onsubmit={(e) => {
          e.preventDefault();
          void doPreview();
        }}
      >
        <label class="stack-tight">
          <span>{$t('cleanup.olderThan')}</span>
          <select bind:value={olderThanDays}>
            <option value={0}>{$t('cleanup.spanAll')}</option>
            <option value={30}>{$t('cleanup.span30')}</option>
            <option value={90}>{$t('cleanup.span90')}</option>
            <option value={365}>{$t('cleanup.span365')}</option>
            <option value={730}>{$t('cleanup.span730')}</option>
          </select>
        </label>
        <button type="submit" class="btn px-6 py-2" disabled={busy}>{$t('cleanup.preview')}</button>
      </form>
    {:else}
      <!-- 下見の結果 → はっきり確認してから実行。 -->
      <p>{$t('cleanup.willPre')}{preview.affected}{$t('cleanup.willPost')}</p>
      <p class="prose-small">{$t('cleanup.keepsPre')}{preview.protected.pinned}{$t('cleanup.keepsMid')}{preview.protected.direct}{$t('cleanup.keepsPost')}</p>
      <p class="prose-small">{$t('cleanup.confirmHelp')}</p>

      {#if preview.affected > 0}
        <form
          class="form stack"
          onsubmit={(e) => {
            e.preventDefault();
            void doExecute();
          }}
        >
          <ReauthField hasPassword={auth.has_password} bind:password bind:reauthCode />
          <div class="hstack">
            <button type="submit" class="btn danger-btn px-6 py-2" disabled={busy}>{$t('cleanup.execute')}</button>
            <button type="button" class="chip" disabled={busy} onclick={cancelPreview}>{$t('security.cancel')}</button>
          </div>
        </form>
      {:else}
        <p>
          <button type="button" class="chip" onclick={cancelPreview}>{$t('security.cancel')}</button>
        </p>
      {/if}
    {/if}

    {#if error}
      <p class="error">{error}</p>
    {/if}
  </section>

  <p class="prose-small" style="margin-top: var(--space-4);">
    <a href="/settings">{$t('security.backToSettings')}</a>
  </p>
{/if}

<style>
  .danger {
    margin-block: var(--space-5);
    border-color: var(--color-danger);
  }
  /* 実行ボタンだけ danger の地色。.btn が形、色はここで足す(§10)。 */
  .danger-btn {
    border-color: var(--color-danger);
    background: var(--fill-danger);
    color: var(--color-danger);
  }
</style>
