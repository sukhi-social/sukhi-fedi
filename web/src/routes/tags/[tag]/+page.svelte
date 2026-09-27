<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { goto } from '$app/navigation';
  import { fetchTimeline, type Status } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { createPager } from '$lib/pager.svelte';
  import StatusCard from '$lib/components/Status.svelte';
  import { t } from '$lib/i18n';
  import type { PageProps } from './$types';

  let { data }: PageProps = $props();

  // タグが変われば load が引き直す。最初の一枚は mount 時点の値から。
  const seed = untrack(() => data);

  // ルートパラメータ。本文中のハッシュタグ（rel="tag"）はここに飛んでくる。
  let tag = $state(seed.tag);

  // fetchPage は今の tag を見る。タグが変わると load が引き直され、下の
  // $effect が新しい一枚に取り替える。
  const pager = createPager<Status>((maxId) => fetchTimeline('tag', { tag, maxId }));
  // load が取った最初の一枚を種にする。
  pager.hydrate(seed.page);

  let loading = $state(false);
  let error = $state<string | null>(seed.error ? $t('common.deliverFailedRetry') : null);
  let initial = $state(false);

  onMount(() => {
    if (!isLoggedIn() || data.error === 'unauthorized') {
      clearToken();
      goto('/');
    }
  });

  // 別のタグへ移ったら(/tags/A → /tags/B)、load が引き直した一枚を種に
  // 取り替える。
  let shownTag = $state(seed.tag);
  $effect(() => {
    if (data.tag === shownTag) return;
    shownTag = data.tag;
    tag = data.tag;
    pager.hydrate(data.page);
    error = data.error ? $t('common.deliverFailedRetry') : null;
  });

  async function more() {
    if (loading) return;
    loading = true;
    try {
      await pager.more();
    } catch {
      // 続きが取れなかったら静かに止める。
    } finally {
      loading = false;
    }
  }
</script>

<header class="timeline page-head">
  <h1>#{tag}</h1>
</header>

<section class="timeline">
  {#if error}
    <p class="error">{error}</p>
  {:else if initial && loading}
    <p class="loading">{$t('common.loading')}</p>
  {:else if pager.items.length === 0 && !loading}
    <p class="prose-small">{$t('timeline.emptyTag', { tag })}</p>
  {/if}

  {#each pager.items as s (s.id)}
    <StatusCard
      status={s}
      ondelete={(d) => (pager.items = pager.items.filter((it) => it.id !== d.id))}
    />
  {/each}

  {#if !initial && (loading || pager.revealing)}
    <p class="loading">{$t('common.loading')}</p>
  {/if}

  {#if pager.hasMore && !loading && !pager.revealing}
    <button class="load-more" onclick={more}>{$t('common.loadMore')}</button>
  {/if}
</section>
