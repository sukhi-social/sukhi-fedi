<script lang="ts">
  import { page } from '$app/state';
  import { getDeco, listPosts, signedIn, when, type Deco, type Post } from '$lib/api';
  import Author from '$lib/Author.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  const slug = $derived(page.params.slug ?? '');

  let deco = $state<Deco | null>(null);
  let posts = $state<Post[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let done = $state(false);

  $effect(() => {
    const s = slug;
    loading = true;
    done = false;
    Promise.all([getDeco(s), listPosts(s)])
      .then(([d, p]) => {
        deco = d;
        posts = p;
        done = p.length < 30;
      })
      .catch(() => (error = 'この板は見つかりませんでした'))
      .finally(() => (loading = false));
  });

  // 「もっと読む」。終わりのないスクロールにはしない ── 読み終えた、
  // という感じが持てるほうがいい。
  async function more() {
    const last = posts.at(-1);
    if (!last) return;
    const next = await listPosts(slug, last.id);
    posts = [...posts, ...next];
    if (next.length === 0) done = true;
  }

</script>

{#if loading}
  <p class="muted">よみこみ中</p>
{:else if !deco}
  <p class="muted">{error ?? 'この板はありません'}</p>
  <p><a href="/">デコの一覧へ</a></p>
{:else}
  <PageHeader title={deco.name} subtitle={deco.description}>
    {#snippet actions()}
      {#if signedIn()}
        <a class="btn write-btn" href="/{slug}/new">書く</a>
      {/if}
    {/snippet}
  </PageHeader>

  {#if !signedIn()}
    <p class="muted">読むのは誰でも。書くには、<a href="/login?next=/{slug}/new">入って</a>ください。</p>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}

  {#if posts.length === 0}
    <p class="muted empty">まだ、なにもありません。最初の一つに、なれます。</p>
  {:else}
    <div class="table-wrap">
      <table class="board-table">
        <thead>
          <tr>
            <th class="num">番号</th>
            <th>タイトル</th>
            <th>作成者</th>
            <th class="date">作成日</th>
          </tr>
        </thead>
        <tbody>
          {#each posts as post, i (post.id)}
            <tr>
              <td class="num muted">{deco.post_count - i}</td>
              <td class="title-cell">
                <a href="/posts/{post.id}">{post.title || '(無題)'}</a>
                {#if post.reply_count > 0}<span class="muted count">{post.reply_count}</span>{/if}
              </td>
              <td><Author author={post.author} compact /></td>
              <td class="date muted">{when(post.created_at)}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>

    {#if done}
      <p class="muted end">ここまでです。</p>
    {:else}
      <button class="btn" type="button" onclick={more}>もっと読む</button>
    {/if}
  {/if}

  <p class="back"><a href="/">デコの一覧へ</a></p>
{/if}

<style>
  .write-btn {
    flex: none;
    text-decoration: none;
  }

  /* 表がはみ出すときは、ページごと横に伸ばさず、表だけ横スクロール
     させる ── 本文は測り(46rem)の中で読みやすいまま。 */
  .table-wrap {
    margin: 0 0 1.25rem;
    overflow-x: auto;
  }

  .board-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.9rem;
  }

  .board-table th {
    text-align: left;
    font-weight: 600;
    color: var(--ink-soft);
    font-size: 0.78rem;
    padding: 0 0.6rem 0.5rem;
    border-bottom: 1px solid var(--line);
    white-space: nowrap;
  }

  .board-table td {
    padding: 0.6rem;
    border-bottom: 1px solid var(--line);
    vertical-align: middle;
  }

  .board-table tbody tr:hover {
    background: var(--paper-raised);
  }

  .board-table th.num,
  .board-table td.num {
    text-align: right;
    width: 3rem;
  }

  .title-cell a {
    font-weight: 600;
    text-decoration: none;
  }

  .title-cell a:hover {
    text-decoration: underline;
  }

  .count {
    margin-left: 0.35rem;
    font-size: 0.78rem;
  }

  .date {
    white-space: nowrap;
  }

  /* 番号は、いちばん削っても困らない列。狭い画面ではそこだけ落とす。 */
  @media (max-width: 640px) {
    .board-table th.num,
    .board-table td.num {
      display: none;
    }
  }

  .empty,
  .end {
    padding: 1rem 0;
  }

  .error {
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
  }

  .back {
    margin-top: 2rem;
  }
</style>
