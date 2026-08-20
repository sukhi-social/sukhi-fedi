<script lang="ts">
  import { goto } from '$app/navigation';
  import { getCurrentAccount, updateProfile, signedIn, type CurrentAccount } from '$lib/api';

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
      error = '保存できませんでした';
    } finally {
      saving = false;
    }
  }
</script>

<h1>プロフィール</h1>

{#if loading}
  <p class="muted">よみこみ中</p>
{:else if !account}
  <p class="muted">読めませんでした。<a href="/login">入りなおして</a>ください。</p>
{:else}
  <p class="muted intro">@{account.acct}</p>

  <form class="card stack" onsubmit={save}>
    <label>
      <span class="muted">表示する名前</span>
      <input type="text" bind:value={displayName} maxlength="100" />
    </label>
    <label>
      <span class="muted">自己紹介(なくてもいい)</span>
      <textarea bind:value={note} rows="4" maxlength="1024"></textarea>
    </label>
    <div class="row">
      <button class="btn" type="submit" disabled={saving}>{saving ? 'ほぞんしています…' : 'ほぞんする'}</button>
      {#if saved}<span class="muted">ほぞんしました</span>{/if}
    </div>
  </form>

  {#if error}<p class="error">{error}</p>{/if}
{/if}

<style>
  h1 {
    font-size: 1.4rem;
    margin: 0 0 0.25rem;
  }

  .intro {
    margin: 0 0 1.25rem;
  }

  .stack {
    display: grid;
    gap: 0.85rem;
    max-width: 28rem;
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
