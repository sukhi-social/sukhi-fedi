<script lang="ts">
  import { page } from '$app/state';
  import { getPost, createReply, signedIn, when, type Post } from '$lib/api';
  import Author from '$lib/Author.svelte';
  import { autoresize, submitOnMetaEnter } from '$lib/textarea';

  const id = $derived(page.params.id ?? '');

  let post = $state<Post | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);

  let text = $state('');
  let posting = $state(false);
  let textEl = $state<HTMLTextAreaElement | null>(null);

  // 本文は HTML(すでに描画済み)なので、引用に使うぶんだけタグを
  // 剥がして短く切る。多段のスレッドは組まない ── 「誰への返信か」は
  // 引用という、みんなに見える形で足りると判断した。
  function quoteSnippet(html: string): string {
    const plain = html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    return plain.length > 60 ? `${plain.slice(0, 60)}…` : plain;
  }

  function quote(target: { author: { display_name: string; acct: string }; content_html: string }) {
    const line = `> **${target.author.display_name}** (@${target.author.acct}): ${quoteSnippet(target.content_html)}\n\n`;
    text = text ? `${line}${text}` : line;
    textEl?.focus();
  }

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
    {#if signedIn()}
      <button type="button" class="linklike" onclick={() => post && quote(post)}>引用して返信する</button>
    {/if}
  </article>

  {#if post.replies && post.replies.length > 0}
    <ul class="list">
      {#each post.replies as r (r.id)}
        <li class="card reply">
          <p><Author author={r.author} at={when(r.created_at)} /></p>
          <div class="body">{@html r.content_html}</div>
          {#if signedIn()}
            <button type="button" class="linklike" onclick={() => quote(r)}>引用して返信する</button>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}

  {#if signedIn()}
    <form class="card write" onsubmit={reply}>
      <textarea
        class="body-input"
        bind:value={text}
        bind:this={textEl}
        rows="3"
        placeholder="つづきを、どうぞ"
        use:autoresize
        use:submitOnMetaEnter
      ></textarea>
      <button class="btn" type="submit" disabled={posting || !text.trim()}>おくる</button>
    </form>
  {:else}
    <p class="muted">読むのは誰でも。書くには、<a href="/login">入って</a>ください。</p>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}
{/if}

<style>
  /* ページの主見出しは、どのページでも 1.4rem(app.css の他の h1 と
     揃える ── 「同じ役割は同じ見た目に」)。著者名と詰めて並べたい
     ここだけ margin は 0 のまま。 */
  h1 {
    font-size: 1.4rem;
    margin: 0;
  }

  .head {
    margin-bottom: 0.75rem;
  }

  .linklike {
    margin-top: 0.6rem;
    background: none;
    border: none;
    padding: 0;
    color: var(--ink-soft);
    text-decoration: underline;
    text-decoration-color: var(--line);
    cursor: pointer;
    font: inherit;
    font-size: 0.8rem;
  }

  .linklike:hover {
    text-decoration-color: var(--sun);
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

  .body-input {
    resize: none;
    overflow: hidden;
    line-height: 1.9;
  }

  .error {
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
  }
</style>
