<script lang="ts">
  import { goto } from '$app/navigation';
  import { getCurrentAccount, updateProfile, signedIn, type CurrentAccount } from '$lib/api';
  import { t } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  let account = $state<CurrentAccount | null>(null);
  let loading = $state(true);

  let displayName = $state('');
  let note = $state('');

  let saving = $state(false);
  let saved = $state(false);
  let error = $state<string | null>(null);

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
  });

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
</style>
