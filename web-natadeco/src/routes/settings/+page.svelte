<script lang="ts">
  import { goto } from '$app/navigation';
  import { getCurrentAccount, updateProfile, signedIn, type CurrentAccount } from '$lib/api';
  import { currentPushState, enablePush, disablePush, type PushState } from '$lib/push';
  import { t } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  let account = $state<CurrentAccount | null>(null);
  let loading = $state(true);

  let displayName = $state('');
  let note = $state('');

  let saving = $state(false);
  let saved = $state(false);
  let error = $state<string | null>(null);

  let pushState = $state<PushState>('unsubscribed');
  let pushBusy = $state(false);
  let pushError = $state<string | null>(null);

  $effect(() => {
    if (!signedIn()) {
      void goto('/login');
      return;
    }
    getCurrentAccount().then((a) => {
      account = a;
      if (a) {
        displayName = a.display_name;
        note = a.note;
      }
      loading = false;
    });
    currentPushState().then((s) => (pushState = s));
  });

  async function togglePush() {
    if (pushBusy) return;
    pushBusy = true;
    pushError = null;
    try {
      pushState = pushState === 'subscribed' ? await disablePush() : await enablePush();
    } catch (e) {
      // 何がどう失敗したか見えないと直しようがないので、生のメッセージを
      // そのまま出す(このボタンは自分だけが見る設定ページの中)。
      pushError = e instanceof Error ? e.message : String(e);
    } finally {
      pushBusy = false;
    }
  }

  async function save(e: SubmitEvent) {
    e.preventDefault();
    if (saving) return;
    saving = true;
    saved = false;
    error = null;
    try {
      const updated = await updateProfile({ display_name: displayName, note });
      account = { ...account!, ...updated };
      saved = true;
    } catch {
      error = t().settings.error;
    } finally {
      saving = false;
    }
  }
</script>

<PageHeader title={t().settings.title} subtitle={account ? `@${account.acct}` : undefined} />

{#if loading}
  <p class="muted">{t().common.loading}</p>
{:else if !account}
  <p class="muted">
    {t().settings.loadError.prefix}<a href="/login">{t().settings.loadError.link}</a
    >{t().settings.loadError.suffix}
  </p>
{:else}
  <form class="card stack" onsubmit={save}>
    <label>
      <span class="muted">{t().settings.displayName}</span>
      <input type="text" bind:value={displayName} maxlength="100" />
    </label>
    <label>
      <span class="muted">{t().settings.note}</span>
      <textarea bind:value={note} rows="4" maxlength="1024"></textarea>
    </label>
    <div class="row">
      <button class="btn" type="submit" disabled={saving}>{saving ? t().settings.saving : t().settings.save}</button>
      {#if saved}<span class="muted">{t().settings.saved}</span>{/if}
    </div>
  </form>

  {#if error}<p class="error">{error}</p>{/if}

  <div class="card stack notify">
    <span class="muted">{t().settings.notifyLabel}</span>
    {#if pushState === 'unsupported'}
      <p class="muted small">{t().settings.notifyUnsupported}</p>
    {:else if pushState === 'denied'}
      <p class="muted small">{t().settings.notifyDenied}</p>
    {:else}
      <button
        type="button"
        class="switch"
        role="switch"
        aria-checked={pushState === 'subscribed'}
        aria-label={pushState === 'subscribed' ? t().settings.notifyOn : t().settings.notifyOff}
        disabled={pushBusy}
        onclick={togglePush}
      >
        <span class="switch-track">
          <span class="switch-knob"></span>
        </span>
      </button>
      <span class="muted small">
        {pushState === 'subscribed' ? t().settings.notifyOn : t().settings.notifyOff}
      </span>
    {/if}
    {#if pushError}<p class="error">{pushError}</p>{/if}
  </div>

  <p class="prose-small"><a href="/settings/security">{t().settings.securityLink}</a></p>
{/if}

<style>
  .stack {
    display: grid;
    gap: 0.85rem;
    max-width: 32rem;
  }

  label {
    display: grid;
    gap: 0.3rem;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 0.8rem;
  }

  .error {
    margin-top: 1rem;
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
  }

  .notify {
    margin-top: 1rem;
  }

  .small {
    font-size: 0.85rem;
  }

  .prose-small {
    margin-top: 1.25rem;
  }

  /* Hinata.svelte のスイッチ(/hello)と同じ寸法 ── 同じ役目の UI は
     同じ見た目に。 */
  .switch {
    display: block;
    padding: 0;
    border: none;
    background: none;
    cursor: pointer;
  }

  .switch:disabled {
    opacity: 0.6;
    cursor: default;
  }

  .switch-track {
    display: block;
    width: 3.4rem;
    height: 1.8rem;
    border-radius: 999px;
    background: var(--blush);
    border: 1px solid var(--sun);
    position: relative;
    transition: background 0.15s ease;
  }

  .switch[aria-checked='true'] .switch-track {
    background: var(--sun);
  }

  .switch-knob {
    position: absolute;
    top: 1px;
    left: 1px;
    width: 1.55rem;
    height: 1.55rem;
    border-radius: 50%;
    background: #fff;
    transition: transform 0.15s ease;
  }

  .switch[aria-checked='true'] .switch-knob {
    transform: translateX(1.6rem);
  }
</style>
