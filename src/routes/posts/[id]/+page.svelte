<script lang="ts">
  import { page } from '$app/state';
  import { getPost, createReply, signedIn, when, localized, type Post } from '$lib/api';
  import { t } from '$lib/i18n.svelte';
  import Author from '$lib/Author.svelte';
  import LangTabs from '$lib/LangTabs.svelte';
  import { autoresize, submitOnMetaEnter } from '$lib/textarea';

  const id = $derived(page.params.id ?? '');

  let post = $state<Post | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);

  let text = $state('');
  let textKo = $state('');
  let replyLang = $state<'ja' | 'ko'>('ja');
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
      .catch(() => (error = t().postDetail.notFound))
      .finally(() => (loading = false));
  });

  // どちらの言語で返信してもいい ── 日本語欄が必須、ではない。
  const jaFilled = $derived(!!text.trim());
  const koFilled = $derived(!!textKo.trim());
  const canReply = $derived(jaFilled || koFilled);

  async function reply(e: SubmitEvent) {
    e.preventDefault();
    if (!canReply || !post) return;
    posting = true;
    error = null;
    try {
      const made = await createReply(
        post.id,
        jaFilled
          ? { status: text, content_i18n: koFilled ? { ko: textKo.trim() } : undefined }
          : { status: textKo }
      );
      // つづきは下に積む ── 掲示板は、上から下へ読むので。
      post = { ...post, replies: [...(post.replies ?? []), made] };
      text = '';
      textKo = '';
      replyLang = 'ja';
    } catch {
      error = t().postDetail.error;
    } finally {
      posting = false;
    }
  }
</script>

{#if loading}
  <p class="muted">{t().common.loading}</p>
{:else if !post}
  <p class="muted">{error ?? t().postDetail.notFoundFallback}</p>
{:else}
  <article class="card">
    <div class="head">
      {#if post.title}<h1>{localized(post.title, post.title_i18n)}</h1>{/if}
      <p><Author author={post.author} at={when(post.created_at)} /></p>
    </div>
    <div class="body">{@html localized(post.content_html, post.content_html_i18n)}</div>
    {#if signedIn()}
      <button type="button" class="linklike" onclick={() => post && quote(post)}>{t().postDetail.quote}</button>
    {/if}
  </article>

  {#if post.replies && post.replies.length > 0}
    <ul class="list">
      {#each post.replies as r (r.id)}
        <li class="card reply">
          <p><Author author={r.author} at={when(r.created_at)} /></p>
          <div class="body">{@html localized(r.content_html, r.content_html_i18n)}</div>
          {#if signedIn()}
            <button type="button" class="linklike" onclick={() => quote(r)}>{t().postDetail.quote}</button>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}

  {#if signedIn()}
    <form class="card write" onsubmit={reply}>
      <LangTabs bind:active={replyLang} />
      {#if replyLang === 'ja'}
        <textarea
          class="body-input"
          bind:value={text}
          bind:this={textEl}
          rows="3"
          placeholder={t().postDetail.replyPlaceholder}
          use:autoresize
          use:submitOnMetaEnter
        ></textarea>
      {:else}
        <textarea
          class="body-input"
          bind:value={textKo}
          rows="3"
          placeholder={t().postDetail.replyPlaceholder}
          use:autoresize
        ></textarea>
      {/if}
      <button class="btn" type="submit" disabled={posting || !canReply}>{t().postDetail.send}</button>
    </form>
  {:else}
    <p class="muted">
      {t().postDetail.readOnly.prefix}<a href="/login">{t().postDetail.readOnly.link}</a
      >{t().postDetail.readOnly.suffix}
    </p>
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
