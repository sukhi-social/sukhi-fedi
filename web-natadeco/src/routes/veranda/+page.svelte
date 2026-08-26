<script lang="ts">
  import { goto } from '$app/navigation';
  import { peekVeranda, signedIn, when, type Veranda } from '$lib/api';
  import { renderEmojis } from '$lib/emoji';
  import { t } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  // ベランダ ── よその板を、追う前に見てみる場所。
  //
  // 引くだけで、なにも残さない。だから通報も削除もこちらではできない
  // し、できないのが正しい。手すりが見えていないと「ナタデコがこれを
  // 載せている」と読まれるので、上に一行はっきり置く。
  let at = $state('');
  let view = $state<Veranda | null>(null);
  let looking = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    if (!signedIn()) void goto('/login?next=/veranda');
  });

  async function look(e: SubmitEvent) {
    e.preventDefault();
    if (!at.trim() || looking) return;
    looking = true;
    error = null;
    try {
      view = await peekVeranda(at.trim());
    } catch {
      view = null;
      error = t().veranda.error;
    } finally {
      looking = false;
    }
  }
</script>

<PageHeader title={t().veranda.title} subtitle={t().veranda.subtitle} />

<p class="railing muted small">{t().veranda.railing}</p>

<form class="find" onsubmit={look}>
  <input type="search" bind:value={at} placeholder={t().veranda.placeholder} />
  <button class="btn" type="submit" disabled={looking || !at.trim()}>{t().veranda.look}</button>
</form>

{#if looking}
  <p class="muted">{t().common.loading}</p>
{:else if error}
  <p class="error">{error}</p>
{:else if view}
  <section class="who">
    {#if view.actor.icon}
      <img class="avatar" src={view.actor.icon} alt="" width="40" height="40" />
    {/if}
    <div>
      <p class="name">{view.actor.name}</p>
      <p class="muted small">
        <a href={view.actor.url} rel="noreferrer">{t().veranda.openRemote}</a>
      </p>
    </div>
  </section>

  {#if view.posts.length === 0}
    <p class="muted empty">{t().veranda.empty}</p>
  {:else}
    <!-- 見えているのは立った話だけ。Lemmy の板の outbox には
         コメントが一件も入っていない ── 「全部見えている」ふりを
         しないよう、そう書いておく。 -->
    <p class="muted small note">{t().veranda.openersOnly}</p>

    <ol class="list">
      {#each view.posts as p (p.id)}
        <li>
          {#if p.title}
            <h2><a href={p.url} rel="noreferrer">{p.title}</a></h2>
          {/if}
          {#if p.published}<p class="muted small">{when(p.published)}</p>{/if}
          {#if p.content_html}
            <div class="body">{@html renderEmojis(p.content_html, null)}</div>
          {/if}
          <p class="muted small"><a href={p.url} rel="noreferrer">{t().veranda.openRemote}</a></p>
        </li>
      {/each}
    </ol>

    {#if view.truncated}
      <p class="muted end">{t().veranda.truncated}</p>
    {/if}
  {/if}
{/if}

<p class="back"><a href="/">{t().common.toDecoList}</a></p>

<style>
  /* 手すり。ここから先がよその家だと、読む前に見えている必要がある。 */
  .railing {
    border-left: 2px solid var(--line);
    padding-left: 0.6rem;
    margin: 0 0 1rem;
  }

  .find {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 1.2rem;
  }

  .find input {
    flex: 1;
    min-width: 0;
  }

  .who {
    display: flex;
    gap: 0.7rem;
    align-items: center;
    margin-bottom: 1rem;
  }

  .avatar {
    border-radius: 50%;
    object-fit: cover;
    background: var(--sun-soft);
    flex: none;
  }

  .name {
    margin: 0;
    font-weight: 700;
  }

  .note {
    margin: 0 0 1rem;
  }

  .list {
    list-style: none;
    margin: 0;
    padding: 0;
  }

  .list li {
    padding: 0.9rem 0;
    border-top: 1px solid var(--line);
  }

  .list h2 {
    font-size: 1rem;
    margin: 0 0 0.2rem;
  }

  .body :global(p) {
    margin: 0.3rem 0;
  }

  /* よその本文なので、画像がこちらの幅を壊さないようにだけ抑える。 */
  .body :global(img) {
    max-width: 100%;
    height: auto;
  }

  .empty,
  .end {
    margin: 1.5rem 0;
  }

  .back {
    margin-top: 2rem;
  }
</style>
