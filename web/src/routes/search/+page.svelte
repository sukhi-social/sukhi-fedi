<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import {
    searchAll,
    getRelationships,
    type Account,
    type Relationship,
    type SearchResult,
    type Tag
  } from '#lib/api.js';
  import { clearToken, isLoggedIn } from '#lib/auth.js';
  import AccountRow from '#lib/components/AccountRow.svelte';
  import { t } from '#lib/i18n.js';

  let q = $state('');
  let pending = $state('');
  let result = $state<SearchResult>({ accounts: [], hashtags: [], statuses: [] });
  let relations = $state(new Map<string, Relationship>());
  let loading = $state(false);
  let error = $state<string | null>(null);
  let searched = $state(false);
  // 「remote 解決中…」表示。WebFinger を踏むので結果が出るまで
  // 数秒待つことがある。
  let resolving = $state(false);

  // URL の `?q=...` で初期化(リンクで飛ばれたとき)
  onMount(() => {
    if (!isLoggedIn()) {
      void goto('/');
      return;
    }
    const initial = page.url.searchParams.get('q') ?? '';
    if (initial) {
      pending = initial;
      q = initial;
      void run();
    }
  });

  // remote 形式 (`@user@host` または `user@host`) のとき resolve=true。
  // local prefix だけのときは resolve は要らない(余計な WebFinger を
  // 蹴らないように)。
  function looksRemote(s: string): boolean {
    const bare = s.trim().replace(/^@/, '');
    return bare.includes('@');
  }

  async function run() {
    if (!q.trim()) return;
    loading = true;
    resolving = looksRemote(q);
    error = null;
    searched = true;
    relations = new Map();

    try {
      result = await searchAll(q, { resolve: looksRemote(q) });
      // 自分以外のアカウントに、その場でフォロー状態を当てる。
      const ids = result.accounts.map((a) => a.id);
      if (ids.length > 0) {
        try {
          const rs = await getRelationships(ids);
          relations = new Map(rs.map((r) => [r.id, r]));
        } catch {
          /* 関係性が取れなくても結果は出す */
        }
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        void goto('/');
        return;
      }
      error = looksRemote(q)
        ? $t('search.errorRemote')
        : $t('search.errorLocal');
      result = { accounts: [], hashtags: [], statuses: [] };
    } finally {
      loading = false;
      resolving = false;
    }
  }

  function submit() {
    q = pending.trim();
    if (!q) return;
    // URL も更新しておくと、リロード・共有しやすい。
    const url = new URL(window.location.href);
    url.searchParams.set('q', q);
    history.replaceState(null, '', url);
    void run();
  }
</script>

<header class="timeline page-head">
  <h1>{$t('search.title')}</h1>
</header>

<form
  class="form stack"
  onsubmit={(e) => {
    e.preventDefault();
    submit();
  }}
>
  <label class="stack-tight">
    <span>{$t('search.labelPre')}<code>@user@host</code> / <code>#tag</code></span>
    <input
      type="text"
      bind:value={pending}
      placeholder={$t('search.placeholder')}
      autocapitalize="none"
      autocorrect="off"
      spellcheck="false"
    />
  </label>

  <button
    type="submit"
    class="btn px-6 py-2"
    disabled={loading || !pending.trim()}
  >
    {loading
      ? resolving ? $t('search.searchingRemote') : $t('search.searching')
      : $t('search.submit')}
  </button>
</form>

{#if error}
  <p class="error">{error}</p>
{/if}

{#if searched && !loading && !error}
  {#if result.accounts.length === 0 && result.hashtags.length === 0}
    <p class="prose-small">
      {$t('search.notFound', { q })}
      {#if !looksRemote(q)}
        {$t('search.remoteHintPre')}<code>@user@host</code>{$t('search.remoteHintPost')}
      {/if}
    </p>
  {:else}
    {#if result.accounts.length > 0}
      <section class="account-list">
        <h2 class="muted" style="font-size: var(--text-sm); margin: var(--space-4) 0 var(--space-2);">
          {$t('search.sectionPeople')}
        </h2>
        {#each result.accounts as a (a.id)}
          <AccountRow account={a} relationship={relations.get(a.id) ?? null} />
        {/each}
      </section>
    {/if}

    {#if result.hashtags.length > 0}
      <section
        class="account-list"
        style="margin-top: var(--space-6);"
      >
        <h2 class="muted" style="font-size: var(--text-sm); margin: var(--space-4) 0 var(--space-2);">
          {$t('search.sectionTags')}
        </h2>
        {#each result.hashtags as t (t.name)}
          <article class="account-row">
            <a class="account-row-link" href={`/timeline?tag=${encodeURIComponent(t.name)}`}>
              <span class="display-name">#{t.name}</span>
            </a>
          </article>
        {/each}
      </section>
    {/if}
  {/if}
{/if}
