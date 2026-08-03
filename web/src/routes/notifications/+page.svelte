<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    getNotifications,
    dismissNotification,
    clearNotifications,
    type Notification
  } from '$lib/api';
  import {
    DIRECT_TYPES,
    markAllSeen,
    clearCounts,
    seenId,
    isNewer,
    type Tier
  } from '$lib/notify';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { createPager } from '$lib/pager.svelte';
  import { renderEmojis } from '$lib/emoji';
  import { phrase } from '$lib/phrase';
  import StatusCard from '$lib/components/Status.svelte';
  import Avatar from '$lib/components/Avatar.svelte';
  import { t } from '$lib/i18n';

  // ふたつのタブ(lib/notify.ts の層と同じ割り方):
  //   あなたへ — 返信・DM・フォロー申請。会話だから、先に出る。
  //   反応     — お気に入りやブーストの郵便受け。開きに来たとき
  //              だけ中身が見える。
  let tier = $state<Tier>('direct');

  // fetchPage は今の tier を見て types/exclude を切り替える。タブを変える
  // たびに reset するので、先読みが古い tier のままになることはない
  // (cursor が合わなくなって捨てられる)。
  const pager = createPager<Notification>((maxId) =>
    getNotifications({
      maxId,
      types: tier === 'direct' ? DIRECT_TYPES : undefined,
      excludeTypes: tier === 'ambient' ? DIRECT_TYPES : undefined
    })
  );
  let loading = $state(false);
  let error = $state<string | null>(null);
  let initial = $state(true);

  // 入ってきた時点の「見た」位置を層ごとに控える。仕切り棒(新着の境い目)は
  // これを基準に引く ── このすぐあと markAllSeen で気配は消すが、棒は
  // 「来たとき何が新しかったか」を指すので、控えた値で描く。
  let seenEntry = $state<Record<Tier, string | null>>({ direct: null, ambient: null });

  // いま見えている層で、上から何件が新着か(新しい順なので新着は先頭に
  // 固まる)。0 なら棒は出さない。
  let newCount = $derived(pager.items.filter((n) => isNewer(n.id, seenEntry[tier])).length);

  onMount(() => {
    if (!isLoggedIn()) {
      goto('/');
      return;
    }
    seenEntry = { direct: seenId('direct'), ambient: seenId('ambient') };
    // ベルを開いた = 通知を見に来た。両方の層をそっと既読にして気配を戻す。
    void markAllSeen();
    void load(true);
  });

  async function load(reset: boolean) {
    if (loading) return;
    loading = true;
    error = null;
    try {
      await (reset ? pager.reset() : pager.more());
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'unknown';
      if (msg === 'unauthorized') {
        clearToken();
        goto('/');
        return;
      }
      error = $t('common.deliverFailedRetry');
    } finally {
      loading = false;
      initial = false;
    }
  }

  function selectTier(next: Tier) {
    if (next === tier) return;
    tier = next;
    void load(true);
  }

  // ひとつ消す。消えたらその場で一覧から外す。失敗したらそのまま。
  async function dismiss(n: Notification) {
    try {
      await dismissNotification(n.id);
      pager.items = pager.items.filter((x) => x.id !== n.id);
    } catch {
      // そっとしておく。
    }
  }

  async function clearAll() {
    if (pager.items.length === 0) return;
    if (!confirm($t('notif.confirmClear'))) return;
    try {
      await clearNotifications();
      pager.items = [];
      // サーバ側は両方のタブとも空になったので、ヘッダーの数も空に。
      clearCounts();
    } catch {
      // 失敗したら何もしない。
    }
  }

  // 「だれが・なにを」の一言。本文(status)は下にカードで出すので、ここは短く。
  function summary(n: Notification): string {
    switch (n.type) {
      case 'favourite':
        return $t('notif.favourited');
      case 'reblog':
        return $t('notif.reblogged');
      case 'follow':
        return $t('notif.followed');
      case 'follow_request':
        return $t('notif.followRequest');
      case 'mention':
        return $t('notif.mentioned');
      case 'status':
        return $t('notif.posted');
      case 'poll':
        return $t('notif.pollEnded');
      case 'update':
        return $t('notif.updated');
      case 'reaction':
        return $t('notif.reacted');
      default:
        return $t('notif.generic');
    }
  }
</script>

<header class="timeline page-head">
  <h1>{$t('notif.title')}</h1>
  {#if pager.items.length > 0}
    <span class="page-nav">
      <button class="chip" onclick={clearAll}>{$t('notif.clearAll')}</button>
    </span>
  {/if}
</header>

<nav class="tabs timeline" aria-label={$t('notif.tabsLabel')}>
  <button
    type="button"
    aria-pressed={tier === 'direct'}
    onclick={() => selectTier('direct')}
  >{$t('notif.tabToYou')}</button>
  <button
    type="button"
    aria-pressed={tier === 'ambient'}
    onclick={() => selectTier('ambient')}
  >{$t('notif.tabReactions')}</button>
</nav>

<section class="timeline">
  {#if error}
    <p class="error">{error}</p>
  {:else if initial && loading}
    <p class="loading">{$t('common.loading')}</p>
  {:else if pager.items.length === 0 && !loading}
    <p class="prose-small">
      {tier === 'direct' ? $t('notif.emptyToYou') : $t('notif.emptyReactions')}
    </p>
  {/if}

  {#each pager.items as n, i (n.id)}
    <article class="notif">
      <header class="notif-head">
        <a class="notif-who" href={`/@${n.account.acct}`}>
          <Avatar
            class="avatar avatar-sm"
            src={n.account.avatar}
            name={n.account.display_name || n.account.username}
          />
          <span class="display-name"
            >{@html renderEmojis(
              phrase(n.account.display_name || n.account.username),
              n.account.emojis
            )}</span
          >
        </a>
        <span class="notif-summary">{summary(n)}</span>
        <button class="chip notif-dismiss" onclick={() => dismiss(n)} aria-label={$t('notif.dismiss')}>
          ×
        </button>
      </header>

      {#if n.status}
        <StatusCard status={n.status} />
      {/if}
    </article>

    <!-- 新着の境い目。ここまでが、前に見てから来たぶん。 -->
    {#if newCount > 0 && i === newCount - 1}
      <div class="notif-divider" role="separator">{$t('notif.newUpToHere')}</div>
    {/if}
  {/each}

  {#if !initial && (loading || pager.revealing)}
    <p class="loading">{$t('common.loading')}</p>
  {/if}

  {#if pager.hasMore && !loading && !pager.revealing}
    <button class="load-more" onclick={() => load(false)}>{$t('common.loadMore')}</button>
  {/if}
</section>

<style>
  .notif {
    border-top: 1px solid var(--color-border);
    padding-top: var(--space-3);
  }
  .notif-head {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    margin-bottom: var(--space-2);
  }
  /* 名前が長いと、この行は「◯◯」+「から返信がきました」で一文になる。
     名前を折り返させると文が二行に割れて、何が起きたのかが読みにくい。
     縮むのは名前のほう ── 意味を持っているのは後半なので。 */
  .notif-who {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    text-decoration: none;
    color: inherit;
    min-width: 0;
  }
  .notif-who .display-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .notif-summary {
    flex: none;
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }
  .notif-dismiss {
    margin-left: auto;
  }

  /* 新着の境い目の棒。「──── 新しい通知は、ここまで ────」。 */
  .notif-divider {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    margin: var(--space-4) 0 var(--space-3);
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }
  .notif-divider::before,
  .notif-divider::after {
    content: '';
    flex: 1 1 0;
    height: 1px;
    background: var(--color-border);
  }
</style>
