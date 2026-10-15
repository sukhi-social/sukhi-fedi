<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    lookupAccount,
    type Account,
    type Relationship
  } from '#lib/api.js';
  import { clearToken } from '#lib/auth.js';
  import { createPager } from '#lib/pager.svelte.js';
  import { loadAccountList, type AccountKind } from '#lib/relations.js';
  import AccountRow from './AccountRow.svelte';
  import { t } from '#lib/i18n.js';

  let { acct, kind }: { acct: string; kind: AccountKind } = $props();

  let owner = $state<Account | null>(null);
  let relations = $state(new Map<string, Relationship>());
  let meId = $state<string | null>(null);
  let loading = $state(false);
  let initial = $state(true);
  let error = $state<string | null>(null);

  // 一覧と一緒に届く relations / meId は、取得のたびに取り込んでから page を
  // 返す。先頭から読み直すとき(maxId なし)は relations も入れ替え、続きの
  // ときは重ねる。
  const pager = createPager<Account>(async (maxId) => {
    const r = await loadAccountList(kind, owner!.id, maxId ? { maxId } : undefined);
    const next = maxId === null ? new Map<string, Relationship>() : new Map(relations);
    for (const [k, v] of r.relations) next.set(k, v);
    relations = next;
    meId = r.meId;
    return r.page;
  });

  onMount(() => {
    void start();
  });

  async function start() {
    loading = true;
    error = null;
    try {
      owner = await lookupAccount(acct);
      await pager.reset();
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        void goto('/');
        return;
      }
      error = msg === 'not_found'
        ? $t('common.acctNotFound', { acct })
        : $t('common.deliverFailed');
    } finally {
      loading = false;
      initial = false;
    }
  }

  async function more() {
    if (!owner || loading) return;
    loading = true;
    try {
      await pager.more();
    } catch {
      // 静かに止める
    } finally {
      loading = false;
    }
  }
</script>

{#if error}
  <p class="error">{error}</p>
  <p><a class="chip" href="/timeline">{$t('common.backToTimeline')}</a></p>
{:else if initial && loading}
  <p class="loading">{$t('common.loading')}</p>
{:else if owner}
  <header class="profile-head" style="padding-bottom: var(--space-3);">
    <p class="muted">
      <a href={`/@${owner.acct}`}>@{owner.acct}</a> {$t(
        kind === 'followers' ? 'accountList.possFollowers' : 'accountList.possFollowing'
      )}
    </p>
  </header>

  <section class="account-list">
    {#if pager.items.length === 0}
      <p class="prose-small">{$t('accountList.empty')}</p>
    {/if}

    {#each pager.items as a (a.id)}
      <AccountRow
        account={a}
        relationship={a.id === meId ? null : relations.get(a.id) ?? null}
      />
    {/each}

    {#if !initial && (loading || pager.revealing)}
      <p class="loading">{$t('common.loading')}</p>
    {/if}

    {#if pager.hasMore && !loading && !pager.revealing}
      <button class="load-more" onclick={more}>{$t('common.loadMore')}</button>
    {/if}
  </section>
{/if}
