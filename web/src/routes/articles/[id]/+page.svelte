<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { goto } from '$app/navigation';
  import type { Status } from '$lib/api';
  import { clearToken } from '$lib/auth';
  import StatusCard from '$lib/components/Status.svelte';
  import Composer from '$lib/components/Composer.svelte';
  import { t } from '$lib/i18n';
  import type { PageProps } from './$types';

  // 記事のリーダーページ。スレッド表示と違い、本体を折りたたまず全文を出し、
  // 返信はその下にそっと並べる。読むことが主役。
  let { data }: PageProps = $props();

  // 別の記事へ移れば load が引き直す。最初の一枚は mount 時点の値から。
  const seed = untrack(() => data);

  function readError(d: PageProps['data']): string | null {
    if (!d.error || d.error === 'unauthorized') return null;
    return d.error === 'not_found' ? $t('thread.noteNotFound') : $t('common.deliverFailed');
  }

  let status = $state<Status | null>(seed.status);
  let descendants = $state<Status[]>(seed.descendants);
  let loading = $state(false);
  let error = $state<string | null>(readError(seed));

  let replyTo = $state<Status | null>(null);
  let quoteOf = $state<Status | null>(null);
  let composerOpen = $state(false);

  // 別の記事へ移ったら load が引き直される。その新しい種を取り込む。
  let shownId = $state(seed.id);
  $effect(() => {
    if (data.id === shownId) return;
    shownId = data.id;
    status = data.status;
    descendants = data.descendants;
    error = readError(data);
  });

  onMount(() => {
    if (data.error === 'unauthorized') {
      clearToken();
      void goto('/');
    }
  });

  function onReply(s: Status) {
    replyTo = s;
    quoteOf = null;
    composerOpen = true;
  }

  function onQuote(s: Status) {
    quoteOf = s;
    replyTo = null;
    composerOpen = true;
    if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function openReply() {
    if (status) onReply(status);
  }

  function onPosted(s: Status) {
    descendants = [...descendants, s];
    composerOpen = false;
    replyTo = null;
    quoteOf = null;
  }

  function onCancel() {
    composerOpen = false;
    replyTo = null;
    quoteOf = null;
  }

  function onDelete(s: Status) {
    if (status && s.id === status.id) {
      void goto('/timeline');
      return;
    }
    descendants = descendants.filter((it) => it.id !== s.id);
  }
</script>

<svelte:head>
  <title>{status?.title ?? $t('thread.note')}</title>
</svelte:head>

{#if error}
  <p class="error">{error}</p>
  <p><a class="chip" href="/timeline">{$t('common.backToTimeline')}</a></p>
{:else if loading}
  <p class="loading">{$t('common.loading')}</p>
{:else if status}
  <article class="reader-page measure">
    <StatusCard status={status} full canReply onreply={onReply} onquote={onQuote} ondelete={onDelete} />
  </article>

  {#if composerOpen}
    <Composer {replyTo} {quoteOf} prefillMention onposted={onPosted} oncancel={onCancel} />
  {:else}
    <div class="measure">
      <button class="chip reply-open" onclick={openReply}>{$t('thread.reply')}</button>
    </div>
  {/if}

  {#if descendants.length > 0}
    <section class="timeline replies">
      {#each descendants as s (s.id)}
        <StatusCard status={s} canReply onreply={onReply} onquote={onQuote} ondelete={onDelete} />
      {/each}
    </section>
  {/if}
{/if}

<style>
  .reply-open {
    margin-top: var(--space-3);
  }
  .replies {
    margin-top: var(--space-3);
    border-top: 1px solid var(--color-border);
  }
</style>
