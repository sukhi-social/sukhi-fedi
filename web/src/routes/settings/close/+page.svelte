<script lang="ts">
  // アカウントを閉じる。入るのと同じくらい易しく: 本人確認とボタン一回、
  // 理由は聞かない、引き止めない。押してから1日は取り消せる(その間、
  // 連合には何も送らない)。session cookie 専用(security ページと同じ)。
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    isLoggedIn,
    fetchAuthState,
    fetchCloseState,
    requestClose,
    cancelClose,
    type AuthState,
    type Reauth,
    type CloseState
  } from '#lib/auth.js';
  import ReauthField from '#lib/components/ReauthField.svelte';
  import { t } from '#lib/i18n.js';

  let auth = $state<AuthState | null>(null);
  let closing = $state<CloseState | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let notice = $state<string | null>(null);
  let busy = $state(false);

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
      closing = await fetchCloseState();
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
      case 'started':
        return $t('close.started');
      default:
        return $t('common.deliverFailed');
    }
  }

  async function doRequest() {
    if (busy) return;
    busy = true;
    error = null;
    notice = null;
    try {
      closing = await requestClose(reauthOf());
      password = '';
      reauthCode = '';
    } catch (e) {
      error = explain(e);
    } finally {
      busy = false;
    }
  }

  async function doCancel() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      closing = await cancelClose();
      notice = $t('close.cancelled');
    } catch (e) {
      error = explain(e);
    } finally {
      busy = false;
    }
  }

  const when = (iso: string) => new Date(iso).toLocaleString();
</script>

<header class="timeline page-head">
  <h1>{$t('close.title')}</h1>
</header>

{#if loading}
  <p class="loading">{$t('common.loading')}</p>
{:else if error && !auth}
  <p class="error">{error}</p>
{:else if auth && !auth.manageable}
  <section class="timeline">
    <p>{$t('security.needRelogin')}</p>
    <p class="prose-small"><a class="chip" href="/login">{$t('security.reloginLink')}</a></p>
  </section>
{:else if auth}
  <section class="timeline">
    <p class="prose-small">{$t('close.intro')}</p>
    <p class="prose-small">{$t('close.what')}</p>
    <p class="prose-small">{$t('close.handle')}</p>
    <p class="prose-small">
      {$t('close.exportPre')}<a href="/settings/migration">{$t('close.exportLink')}</a>{$t('close.exportPost')}
    </p>
    <p class="prose-small">{$t('close.mail')}</p>

    {#if closing?.pending}
      <p>{$t('close.pending', { at: when(closing.pending.scheduled_for) })}</p>
      <p class="prose-small">{$t('close.pendingHelp')}</p>
      <p>
        <button type="button" class="btn px-6 py-2" disabled={busy} onclick={doCancel}>
          {$t('close.cancel')}
        </button>
      </p>
    {:else}
      {#if notice}
        <p>{notice}</p>
      {/if}
      <form
        class="form stack"
        onsubmit={(e) => {
          e.preventDefault();
          void doRequest();
        }}
      >
        <ReauthField hasPassword={auth.has_password} bind:password bind:reauthCode />
        <div>
          <button type="submit" class="btn px-6 py-2" disabled={busy}>{$t('close.request')}</button>
        </div>
      </form>
    {/if}

    {#if error}
      <p class="error">{error}</p>
    {/if}
  </section>

  <p class="prose-small">
    <a href="/settings">{$t('security.backToSettings')}</a>
  </p>
{/if}
