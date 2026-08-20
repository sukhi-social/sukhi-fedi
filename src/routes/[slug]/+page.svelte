<script lang="ts">
  import { page } from '$app/state';
  import { getDeco, listPosts, signedIn, when, type Deco, type Post } from '$lib/api';
  import Author from '$lib/Author.svelte';

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
  <div class="top">
    <div>
      <h1>{deco.name}</h1>
      {#if deco.description}<p class="muted intro">{deco.description}</p>{/if}
    </div>
    {#if signedIn()}
      <a class="btn" href="/{slug}/new">書く</a>
    {/if}
  </div>

  {#if !signedIn()}
    <p class="muted">読むのは誰でも。書くには、<a href="/login?next=/{slug}/new">入って</a>ください。</p>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}

  {#if posts.length === 0}
    <p class="muted empty">まだ、なにもありません。最初の一つに、なれます。</p>
  {:else}
    <ul class="list">
      {#each posts as post (post.id)}
        <li class="card">
          <div class="head">
            {#if post.title}
              <a class="title" href="/posts/{post.id}">{post.title}</a>
            {/if}
            <Author author={post.author} at={when(post.created_at)} />
          </div>
          <div class="body">{@html post.content_html}</div>
          <p class="muted">
            {#if post.reply_count > 0}
              <a href="/posts/{post.id}">{post.reply_count} のつづき</a>
            {:else}
              <a href="/posts/{post.id}">ひらく</a>
            {/if}
          </p>
        </li>
      {/each}
    </ul>

    {#if done}
      <p class="muted end">ここまでです。</p>
    {:else}
      <button class="btn" type="button" onclick={more}>もっと読む</button>
    {/if}
  {/if}

  <p class="back"><a href="/">デコの一覧へ</a></p>
{/if}

<style>
  h1 {
    font-size: 1.4rem;
    margin: 0 0 0.25rem;
  }

  .intro {
    margin: 0 0 1.25rem;
  }

  .top {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 1rem;
    margin-bottom: 1.25rem;
  }

  .top .btn {
    flex: none;
    text-decoration: none;
  }

  .list {
    list-style: none;
    margin: 0 0 1.25rem;
    padding: 0;
    display: grid;
    gap: 0.75rem;
  }

  .head {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 0.6rem;
    text-decoration: none;
    margin-bottom: 0.5rem;
  }

  .title {
    font-weight: 600;
    text-decoration: none;
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
