<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    getFollowRequests,
    authorizeFollowRequest,
    rejectFollowRequest,
    getFollowInvites,
    createFollowInvite,
    deleteFollowInvite,
    verifyCredentials,
    type Account,
    type FollowInvite
  } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import AccountRow from '$lib/components/AccountRow.svelte';
  import { t } from '$lib/i18n';

  let accounts = $state<Account[]>([]);
  let invites = $state<FollowInvite[]>([]);
  let username = $state('');
  let copied = $state<string | null>(null);
  let loading = $state(false);
  let initial = $state(true);
  let error = $state<string | null>(null);
  // 連打で二重に答えてしまわないよう、進行中の id を控えておく。
  let busy = $state(new Set<string>());

  onMount(() => {
    if (!isLoggedIn()) {
      goto('/');
      return;
    }
    void load();
  });

  function inviteLink(code: string): string {
    return `${location.origin}/users/${username}/invites/${code}`;
  }

  async function copy(code: string) {
    try {
      await navigator.clipboard.writeText(inviteLink(code));
      copied = code;
    } catch {
      // クリップボードが使えない環境では、そっと何もしない。
    }
  }

  async function newInvite() {
    try {
      const invite = await createFollowInvite();
      invites = [invite, ...invites];
    } catch {
      error = $t('requests.failed');
    }
  }

  async function revoke(code: string) {
    try {
      await deleteFollowInvite(code);
      invites = invites.filter((i) => i.code !== code);
    } catch {
      error = $t('requests.failed');
    }
  }

  async function load() {
    loading = true;
    error = null;
    try {
      const [reqs, invs, me] = await Promise.all([
        getFollowRequests(),
        getFollowInvites(),
        verifyCredentials()
      ]);
      accounts = reqs;
      invites = invs;
      username = me.username;
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'unknown';
      if (msg === 'unauthorized') {
        clearToken();
        goto('/');
        return;
      }
      error = $t('requests.failed');
    } finally {
      loading = false;
      initial = false;
    }
  }

  async function answer(account: Account, approve: boolean) {
    if (busy.has(account.id)) return;
    busy = new Set(busy).add(account.id);
    try {
      if (approve) {
        await authorizeFollowRequest(account.id);
      } else {
        await rejectFollowRequest(account.id);
      }
      // 答えたら、その場でそっと一覧から外す。
      accounts = accounts.filter((a) => a.id !== account.id);
    } catch {
      error = $t('requests.failed');
    } finally {
      const next = new Set(busy);
      next.delete(account.id);
      busy = next;
    }
  }
</script>

<header class="timeline page-head">
  <h1>{$t('requests.title')}</h1>
</header>

<section class="timeline">
  {#if error}
    <p class="error">{error}</p>
  {/if}

  {#if initial && loading}
    <p class="loading">{$t('common.loading')}</p>
  {:else if accounts.length === 0}
    <p class="prose-small">{$t('requests.empty')}</p>
  {/if}

  {#each accounts as account (account.id)}
    <div class="request-row">
      <AccountRow {account} relationship={null} />
      <div class="request-actions">
        <button
          class="btn px-4 py-1"
          disabled={busy.has(account.id)}
          onclick={() => answer(account, true)}
        >
          {$t('requests.approve')}
        </button>
        <button
          class="btn-quiet px-4 py-1"
          disabled={busy.has(account.id)}
          onclick={() => answer(account, false)}
        >
          {$t('requests.reject')}
        </button>
      </div>
    </div>
  {/each}
</section>

<section class="timeline invites">
  <h2>{$t('invites.heading')}</h2>
  <p class="prose-small muted">{$t('invites.hint')}</p>
  <button class="btn px-4 py-1" onclick={newInvite}>{$t('invites.create')}</button>

  {#if invites.length === 0}
    <p class="prose-small muted">{$t('invites.empty')}</p>
  {/if}

  {#each invites as invite (invite.code)}
    <div class="invite-row">
      <code class="invite-link">{inviteLink(invite.code)}</code>
      <div class="request-actions">
        <button class="btn px-4 py-1" onclick={() => copy(invite.code)}>
          {copied === invite.code ? $t('invites.copied') : $t('invites.copy')}
        </button>
        <button class="btn-quiet px-4 py-1" onclick={() => revoke(invite.code)}>
          {$t('invites.revoke')}
        </button>
      </div>
    </div>
  {/each}
</section>

<style>
  .request-row {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-3) 0;
  }
  .request-actions {
    display: flex;
    gap: var(--space-3);
    padding-left: var(--space-3);
  }
  .invites {
    margin-top: var(--space-6);
  }
  .invite-row {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-3) 0;
  }
  .invite-link {
    word-break: break-all;
    font-size: 0.85em;
  }
</style>
