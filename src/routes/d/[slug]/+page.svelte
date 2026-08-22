<script lang="ts">
  import { page } from '$app/state';
  import { getDeco, listPosts, signedIn, when, localized, type Deco, type Post } from '$lib/api';
  import { t } from '$lib/i18n.svelte';
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
      .catch(() => (error = t().board.notFound))
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
  <p class="muted">{t().common.loading}</p>
{:else if !deco}
  <p class="muted">{error ?? t().board.notFoundFallback}</p>
  <p><a href="/">{t().common.toDecoList}</a></p>
{:else}
  <PageHeader
    title="{localized(deco.name, deco.name_i18n)}{t().home.separator}{t().home.title}"
    subtitle={deco.description ? localized(deco.description, deco.description_i18n) : null}
  >
    {#snippet actions()}
      {#if signedIn()}
        <a class="btn write-btn" href="/d/{slug}/new">{t().board.write}</a>
      {/if}
    {/snippet}
  </PageHeader>

  {#if !signedIn()}
    <p class="muted">
      {t().board.readOnly.prefix}<a href="/login?next=/d/{slug}/new">{t().board.readOnly.link}</a
      >{t().board.readOnly.suffix}
    </p>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}

  {#if posts.length === 0}
    <p class="muted empty">{t().board.empty}</p>
  {:else}
    <div class="table-wrap">
      <table class="board-table">
        <thead>
          <tr>
            <th class="num">{t().board.colNum}</th>
            <th>{t().board.colTitle}</th>
            <th>{t().board.colAuthor}</th>
            <th class="date">{t().board.colDate}</th>
          </tr>
        </thead>
        <tbody>
          {#each posts as post, i (post.id)}
            <tr>
              <td class="num muted">{deco.post_count - i}</td>
              <td class="title-cell">
                <a href="/posts/{post.id}">{localized(post.title, post.title_i18n) || t().board.untitled}</a>
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
      <p class="muted end">{t().board.end}</p>
    {:else}
      <button class="btn" type="button" onclick={more}>{t().board.more}</button>
    {/if}
  {/if}

  <p class="back"><a href="/">{t().common.toDecoList}</a></p>
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
