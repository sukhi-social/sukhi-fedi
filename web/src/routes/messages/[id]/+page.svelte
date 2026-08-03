<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import {
    getConversationStatuses,
    markConversationRead,
    type Conversation,
    type Status
  } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { createPager } from '$lib/pager.svelte';
  import { renderEmojis } from '$lib/emoji';
  import { phrase } from '$lib/phrase';
  import StatusCard from '$lib/components/Status.svelte';
  import Composer from '$lib/components/Composer.svelte';
  import { t } from '$lib/i18n';

  let convo = $state<Conversation | null>(null);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let initial = $state(true);

  let id = $derived($page.params.id ?? '');

  // 会話の中身は新しい順で来る。画面は古いものが上、いつもの会話の並び。
  const pager = createPager<Status>((maxId) => getConversationStatuses(id, { maxId }));
  let messages = $derived([...pager.items].reverse());

  onMount(() => {
    if (!isLoggedIn()) {
      void goto('/');
      return;
    }
    void load(true);
  });

  async function load(reset: boolean) {
    if (loading) return;
    loading = true;
    error = null;
    try {
      if (reset) {
        // 会話そのものを引く口は無いが、既読にする口が会話を返す。開いた
        // ということは読んだということなので、ここで一度で足りる ── 一覧を
        // 丸ごと引いて自分の行を探す必要も、もう無い。
        convo = await markConversationRead(id);
      }
      await (reset ? pager.reset() : pager.more());
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        void goto('/');
        return;
      }
      error = $t('common.deliverFailedRetry');
    } finally {
      loading = false;
      initial = false;
    }
  }

  // 返信は、いまスレッドにいる相手みんなに宛てる。グループのまま返したい
  // ので、最後のメッセージの author 一人だけでなく、会話の参加者全員を
  // 宛先にする(でないと黙って一対一に縮んでしまう)。
  let lastStatus = $derived(messages.length > 0 ? messages[messages.length - 1] : null);
  let recipients = $derived((convo?.accounts ?? []).map((a) => a.acct));

  function withLabel(c: Conversation): string {
    const names = c.accounts.map((a) => a.display_name || a.username);
    if (names.length === 0) return $t('messages.self');
    return names.join($t('messages.nameSep'));
  }

  function onPosted(s: Status) {
    // 送れた返事は、その場でスレッドの末尾に足す。pager は新しい順なので
    // 頭へ。
    pager.items = [s, ...pager.items];
  }
</script>

<header class="timeline page-head">
  <a class="chip" href="/messages">{$t('messages.back')}</a>
  {#if convo}
    <h1>{@html renderEmojis(phrase(withLabel(convo)), convo.accounts[0]?.emojis)}</h1>
  {/if}
</header>

<section class="timeline thread">
  {#if error}
    <p class="error">{error}</p>
  {:else if initial && loading}
    <p class="loading">{$t('common.loading')}</p>
  {:else if messages.length === 0}
    <p class="prose-small">{$t('messages.threadEmpty')}</p>
  {:else}
    <!-- 会話は上へ遡るもの。「もっと読む」は上に置く。 -->
    {#if pager.hasMore && !loading && !pager.revealing}
      <button class="load-more" onclick={() => load(false)}>{$t('common.loadMore')}</button>
    {/if}
    {#if !initial && (loading || pager.revealing)}
      <p class="loading">{$t('common.loading')}</p>
    {/if}

    {#each messages as s (s.id)}
      <StatusCard status={s} />
    {/each}
  {/if}
</section>

{#if lastStatus && !initial && !error}
  <Composer
    replyTo={lastStatus}
    prefillRecipients={recipients}
    dmConversationId={id}
    onposted={onPosted}
  />
{/if}
