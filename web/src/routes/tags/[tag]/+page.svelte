<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import { fetchTimeline, type Status } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { createPager } from '$lib/pager.svelte';
  import StatusCard from '$lib/components/Status.svelte';
  import { t } from '$lib/i18n';

  // ルートパラメータ。本文中のハッシュタグ（rel="tag"）はここに飛んでくる。
  let tag = $derived(decodeURIComponent($page.params.tag ?? ''));

  // fetchPage は今の tag を見る。タグが変わると下の $effect が reset する。
  const pager = createPager<Status>((maxId) => fetchTimeline('tag', { tag, maxId }));
  let loading = $state(false);
  let error = $state<string | null>(null);
  let initial = $state(true);

  onMount(() => {
    if (!isLoggedIn()) {
      goto('/');
      return;
    }
  });

  // タグが変わったら（/tags/A → /tags/B の遷移）頭から読み直す。
  //
  // **引き金だけを依存にする。** load は先頭で loading を読むので、それが
  // 依存に乗ると `loading = true` / `finally { loading = false }` が自分を
  // 呼び戻して止まらなくなる ── タグのページを開いているあいだ、ずっと
  // 取り直しつづける。untrack で切る（/messages と /messages/[id] が同じ形）。
  $effect(() => {
    void tag;
    untrack(() => {
      if (isLoggedIn()) void load(true);
    });
  });

  async function load(reset: boolean) {
    if (loading || !tag) return;
    loading = true;
    error = null;
    if (reset) initial = true;
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
    <button class="load-more" onclick={() => load(false)}>{$t('common.loadMore')}</button>
  {/if}
</section>
