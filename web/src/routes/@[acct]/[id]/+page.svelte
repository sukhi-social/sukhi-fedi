<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { goto } from '$app/navigation';
  import type { Status } from '#lib/api.js';
  import { clearToken } from '#lib/auth.js';
  import StatusCard from '#lib/components/Status.svelte';
  import Composer from '#lib/components/Composer.svelte';
  import { t } from '#lib/i18n.js';
  import type { PageProps } from './$types';

  let { data }: PageProps = $props();

  // 別のスレッドへ移れば load が引き直す。最初の一枚は mount 時点の値から。
  const seed = untrack(() => data);

  function threadError(d: PageProps['data']): string | null {
    if (!d.error || d.error === 'unauthorized') return null;
    return d.error === 'not_found' ? $t('thread.noteNotFound') : $t('common.deliverFailed');
  }

  let status = $state<Status | null>(seed.status);
  let ancestors = $state<Status[]>(seed.ancestors);
  let descendants = $state<Status[]>(seed.descendants);
  let loading = $state(false);
  let error = $state<string | null>(threadError(seed));

  let replyTo = $state<Status | null>(null);
  let quoteOf = $state<Status | null>(null);
  let composerOpen = $state(false);

  // 別のスレッドへ移ったら load が引き直される。その新しい種を取り込む。
  let shownId = $state(seed.id);
  $effect(() => {
    if (data.id === shownId) return;
    shownId = data.id;
    status = data.status;
    ancestors = data.ancestors;
    descendants = data.descendants;
    error = threadError(data);
  });

  onMount(() => {
    if (data.error === 'unauthorized') {
      clearToken();
      void goto('/');
    }
  });

  // どのノートにも返信できる。返信先の公開範囲は Composer が引き継ぐので、
  // DM への返信はそのまま direct のまま、同じスレッドに繋がる。
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
    // 送れた返事はその場でスレッドの末尾に足す。
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
    // 本体を消したらこのスレッドはもう開けないので、タイムラインへ戻る。
    if (status && s.id === status.id) {
      void goto('/timeline');
      return;
    }
    ancestors = ancestors.filter((it) => it.id !== s.id);
    descendants = descendants.filter((it) => it.id !== s.id);
  }
</script>

{#if error}
  <p class="error">{error}</p>
  <p><a class="chip" href="/timeline">{$t('common.backToTimeline')}</a></p>
{:else if loading}
  <p class="loading">{$t('common.loading')}</p>
{:else if status}
  <section class="timeline thread">
    {#each ancestors as s (s.id)}
      <StatusCard status={s} canReply onreply={onReply} onquote={onQuote} ondelete={onDelete} />
    {/each}

    <div class="focused">
      <StatusCard status={status} canReply onreply={onReply} onquote={onQuote} ondelete={onDelete} />
    </div>

    {#each descendants as s (s.id)}
      <StatusCard status={s} canReply onreply={onReply} onquote={onQuote} ondelete={onDelete} />
    {/each}
  </section>

  {#if composerOpen}
    <Composer {replyTo} {quoteOf} prefillMention onposted={onPosted} oncancel={onCancel} />
  {:else}
    <button class="chip reply-open" onclick={openReply}>{$t('thread.reply')}</button>
  {/if}
{/if}

<style>
  /* スレッドの中で、いま見ているノートだけ、そっと際立たせる。 */
  .focused {
    border-left: 3px solid var(--color-text);
  }
  .reply-open {
    margin-top: var(--space-3);
  }
</style>
