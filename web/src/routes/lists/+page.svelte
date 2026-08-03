<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { getLists, createList, deleteList, type List } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { t } from '$lib/i18n';
  import { refreshCircles } from '$lib/circles';

  let lists = $state<List[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let newTitle = $state('');
  let creating = $state(false);

  onMount(() => {
    if (!isLoggedIn()) {
      goto('/');
      return;
    }
    void load();
  });

  async function load() {
    loading = true;
    error = null;
    try {
      lists = await getLists();
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        goto('/');
        return;
      }
      error = $t('common.readFailed');
    } finally {
      loading = false;
    }
  }

  async function create() {
    const title = newTitle.trim();
    if (!title || creating) return;
    creating = true;
    try {
      const l = await createList(title);
      lists = [...lists, l];
      newTitle = '';
    } catch {
      // 失敗時はそのまま。
    } finally {
      creating = false;
    }
  }

  async function remove(l: List) {
    if (!confirm($t('lists.confirmDelete', { title: l.title }))) return;
    try {
      await deleteList(l.id);
      lists = lists.filter((x) => x.id !== l.id);
      void refreshCircles();
    } catch {
      // 失敗時はそのまま。
    }
  }

</script>

<header class="timeline page-head">
  <h1>{$t('lists.title')}</h1>
</header>

<section class="timeline">
  <form
    class="form"
    onsubmit={(e) => {
      e.preventDefault();
      void create();
    }}
    style="margin-bottom: var(--space-4);"
  >
    <div style="display: flex; gap: var(--space-2);">
      <input
        type="text"
        bind:value={newTitle}
        placeholder={$t('lists.newPlaceholder')}
        maxlength="60"
        style="flex: 1;"
      />
      <button type="submit" class="btn px-6 py-2" disabled={creating || !newTitle.trim()}>{$t('lists.create')}</button>
    </div>
  </form>

  {#if error}
    <p class="error">{error}</p>
  {:else if loading}
    <p class="loading">{$t('common.loading')}</p>
  {:else if lists.length === 0}
    <p class="prose-small">{$t('lists.empty')}</p>
  {:else}
    {#each lists as l (l.id)}
      <article class="list-row">
        <a class="list-link" href={`/lists/${l.id}`}>{l.title}</a>
        <button type="button" class="chip" onclick={() => remove(l)}>{$t('lists.delete')}</button>
      </article>
    {/each}
  {/if}
</section>

<style>
  .list-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    padding: var(--space-3) 0;
    border-bottom: 1px solid var(--color-border);
  }
  /* 下線を消さない。この面のリンクは下線で分かる約束(@user@host も時刻も
     そう)なのに、ここだけ消して hover のときだけ戻していた ── 指で触る
     画面に hover は無いので、**押せると分かるのが「削除」だけ**になって
     いた。いちばん目立つ操作が、いちばん戻せない操作だった。 */
  .list-link {
    flex: 1;
    color: inherit;
    font-weight: 600;
  }
</style>
