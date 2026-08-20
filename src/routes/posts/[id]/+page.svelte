<script lang="ts">
  import { page } from '$app/state';
  import { getPost, createReply, signedIn, when, type Post } from '$lib/api';
  import Author from '$lib/Author.svelte';

  const id = $derived(page.params.id ?? '');

  let post = $state<Post | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);

  let text = $state('');
  let posting = $state(false);

  $effect(() => {
    const target = id;
    loading = true;
    getPost(target)
      .then((p) => (post = p))
      .catch(() => (error = 'この投稿は見つかりませんでした'))
      .finally(() => (loading = false));
  });

  async function reply(e: SubmitEvent) {
    e.preventDefault();
    if (!text.trim() || !post) return;
    posting = true;
    error = null;
    try {
      const made = await createReply(post.id, { status: text });
      // つづきは下に積む ── 掲示板は、上から下へ読むので。
      post = { ...post, replies: [...(post.replies ?? []), made] };
      text = '';
    } catch {
      error = '書けませんでした';
    } finally {
      posting = false;
    }
  }
</script>

{#if loading}
  <p class="muted">よみこみ中</p>
{:else if !post}
  <p class="muted">{error ?? 'この投稿はありません'}</p>
{:else}
  <article class="card">
    <div class="head">
      {#if post.title}<h1>{post.title}</h1>{/if}
      <p><Author author={post.author} at={when(post.created_at)} /></p>
    </div>
    <div class="body">{@html post.content_html}</div>
  </article>

  {#if post.replies && post.replies.length > 0}
    <ul class="list">
      {#each post.replies as r (r.id)}
        <li class="card reply">
          <p><Author author={r.author} at={when(r.created_at)} /></p>
          <div class="body">{@html r.content_html}</div>
        </li>
      {/each}
    </ul>
  {/if}

  {#if signedIn()}
    <form class="card write" onsubmit={reply}>
      <textarea bind:value={text} rows="3" placeholder="つづきを、どうぞ"></textarea>
      <button class="btn" type="submit" disabled={posting || !text.trim()}>おくる</button>
    </form>
  {:else}
    <p class="muted">読むのは誰でも。書くには、ログインしてください。</p>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}
{/if}

<style>
  h1 {
    font-size: 1.25rem;
    margin: 0;
  }

  .head {
    margin-bottom: 0.75rem;
  }

  .head p {
    margin: 0.25rem 0 0;
  }

  .list {
    list-style: none;
    margin: 1rem 0;
    padding: 0;
    display: grid;
    gap: 0.6rem;
  }

  .reply {
    margin-left: 1.25rem;
  }

  .reply p {
    margin: 0 0 0.4rem;
  }

  .write {
    display: grid;
    gap: 0.7rem;
    justify-items: start;
    margin-top: 1.25rem;
  }

  .write textarea {
    width: 100%;
  }

  .error {
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
  }
</style>
