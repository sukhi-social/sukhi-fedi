<script lang="ts">
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import {
    getPost,
    createReply,
    updatePost,
    deletePost,
    getCurrentAccount,
    signedIn,
    when,
    localized,
    type Post,
    type Visibility
  } from '$lib/api';
  import { renderEmojis } from '$lib/emoji';
  import { t, getLang, langNames } from '$lib/i18n.svelte';
  import Author from '$lib/Author.svelte';
  import Reactions from '$lib/Reactions.svelte';
  import LangTabs from '$lib/LangTabs.svelte';
  import VisibilityPicker from '$lib/VisibilityPicker.svelte';
  import MarkdownToolbar from '$lib/MarkdownToolbar.svelte';
  import { autoresize, submitOnMetaEnter } from '$lib/textarea';

  const id = $derived(page.params.id ?? '');

  let post = $state<Post | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);

  let text = $state('');
  let textKo = $state('');
  let replyLang = $state<'ja' | 'ko'>(getLang());
  // 返事の出発点は、返す相手に合わせる ── ローカルに置かれた話へ
  // 黙って外向きの返事が付かないように（サーバ側も同じ規則）。
  let visibility = $state<Visibility>('public');
  let posting = $state(false);
  let textEl = $state<HTMLTextAreaElement | null>(null);
  let textElKo = $state<HTMLTextAreaElement | null>(null);

  // 直す。書いたときの主言語はそのまま(タブで書き直し先を選ばせると、
  // もう一言語だけ直したかった人が、うっかり主言語を入れ替えてしまう)。
  // もう一つの言語ぶんが無い投稿には、その欄自体を出さない。
  let myAcct = $state<string | null>(null);

  $effect(() => {
    if (signedIn()) getCurrentAccount().then((a) => (myAcct = a?.acct ?? null));
  });

  let editingId = $state<number | null>(null);
  let editTitle = $state('');
  let editPrimary = $state('');
  let editSecondary = $state('');
  let editSecondaryLang = $state<'ja' | 'ko' | null>(null);
  let editSaving = $state(false);
  let editError = $state<string | null>(null);
  let editEl = $state<HTMLTextAreaElement | null>(null);

  function secondaryLangOf(p: Post): 'ja' | 'ko' | null {
    if ('ko' in p.content_i18n) return 'ko';
    if ('ja' in p.content_i18n) return 'ja';
    return null;
  }

  function startEdit(p: Post) {
    editingId = p.id;
    editTitle = p.title ?? '';
    editPrimary = p.content;
    editSecondaryLang = secondaryLangOf(p);
    editSecondary = editSecondaryLang ? (p.content_i18n[editSecondaryLang] ?? '') : '';
    editError = null;
  }

  function cancelEdit() {
    editingId = null;
  }

  async function saveEdit(target: Post, isRoot: boolean) {
    if (editSaving || !editPrimary.trim()) return;
    editSaving = true;
    editError = null;
    try {
      const body: { title?: string; status: string; content_i18n?: Record<string, string> } = {
        status: editPrimary
      };
      if (isRoot) body.title = editTitle;
      if (editSecondaryLang) body.content_i18n = { [editSecondaryLang]: editSecondary };

      const updated = await updatePost(target.id, body);

      if (!post) return;
      post =
        target.id === post.id
          ? { ...post, ...updated }
          : { ...post, replies: post.replies?.map((r) => (r.id === target.id ? { ...r, ...updated } : r)) };
      editingId = null;
    } catch {
      editError = t().postDetail.editError;
    } finally {
      editSaving = false;
    }
  }

  // 消す。取り消せないので、いきなり消さずワンクッション挟む
  // (押し間違いガード)。
  let deletingId = $state<number | null>(null);
  let deleteError = $state<string | null>(null);
  let deleteBusy = $state(false);

  function askDelete(targetId: number) {
    deletingId = targetId;
    deleteError = null;
  }

  function cancelDelete() {
    deletingId = null;
  }

  async function confirmDelete(target: Post, isRoot: boolean) {
    if (deleteBusy) return;
    deleteBusy = true;
    try {
      await deletePost(target.id);
      if (isRoot) {
        await goto('/');
        return;
      }
      if (post) post = { ...post, replies: post.replies?.filter((r) => r.id !== target.id) };
      deletingId = null;
    } catch {
      deleteError = t().postDetail.deleteError;
    } finally {
      deleteBusy = false;
    }
  }

  $effect(() => {
    const target = id;
    loading = true;
    getPost(target)
      .then((p) => {
        post = p;
        visibility = p.local_only ? 'local' : 'public';
      })
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
          ? { status: text, content_i18n: koFilled ? { ko: textKo.trim() } : undefined, visibility }
          : { status: textKo, visibility }
      );
      // つづきは下に積む ── 掲示板は、上から下へ読むので。表示は平ら
      // なまま(スレッドを何段にも組まない)。
      post = { ...post, replies: [...(post.replies ?? []), made] };
      text = '';
      textKo = '';
      replyLang = getLang();
      visibility = post.local_only ? 'local' : 'public';
    } catch {
      error = t().postDetail.error;
    } finally {
      posting = false;
    }
  }

</script>

{#snippet editForm(target: Post, isRoot: boolean)}
  <form
    class="edit-form card"
    onsubmit={(e) => {
      e.preventDefault();
      void saveEdit(target, isRoot);
    }}
  >
    {#if isRoot}
      <input type="text" bind:value={editTitle} required maxlength="120" />
    {/if}
    <MarkdownToolbar bind:value={editPrimary} el={editEl} />
    <textarea
      class="body-input"
      bind:value={editPrimary}
      bind:this={editEl}
      rows="3"
      use:autoresize
      use:submitOnMetaEnter
    ></textarea>
    {#if editSecondaryLang}
      <label class="muted small secondary-label">
        {langNames[editSecondaryLang]}
        <textarea class="body-input" bind:value={editSecondary} rows="2" use:autoresize></textarea>
      </label>
    {/if}
    <div class="row">
      <button class="btn" type="submit" disabled={editSaving || !editPrimary.trim()}
        >{editSaving ? t().postDetail.editSaving : t().postDetail.editSave}</button
      >
      <button class="btn ghost" type="button" onclick={cancelEdit}>{t().postDetail.editCancel}</button>
    </div>
    {#if editError}<p class="error">{editError}</p>{/if}
  </form>
{/snippet}

{#snippet deleteConfirm(target: Post, isRoot: boolean)}
  <p class="confirm-delete">
    {t().postDetail.deleteConfirm}
    <span class="row">
      <button
        type="button"
        class="linklike"
        disabled={deleteBusy}
        onclick={() => confirmDelete(target, isRoot)}>{t().postDetail.deleteConfirmYes}</button
      >
      <button type="button" class="linklike" disabled={deleteBusy} onclick={cancelDelete}
        >{t().postDetail.editCancel}</button
      >
    </span>
  </p>
  {#if deleteError}<p class="error">{deleteError}</p>{/if}
{/snippet}

{#if loading}
  <p class="muted">{t().common.loading}</p>
{:else if !post}
  <p class="muted">{error ?? t().postDetail.notFoundFallback}</p>
{:else}
  <article class="post-body">
    {#if editingId === post.id}
      {@render editForm(post, true)}
    {:else if deletingId === post.id}
      {@render deleteConfirm(post, true)}
    {:else}
      <div class="head">
        {#if post.title}<h1>{localized(post.title, post.title_i18n)}</h1>{/if}
        <p>
          <Author author={post.author} at={when(post.created_at)} />
          {#if post.local_only}<span class="local-badge">{t().visibility.badge}</span>{/if}
        </p>
      </div>
      <div class="body">{@html renderEmojis(localized(post.content_html, post.content_html_i18n), post.emojis)}</div>
      <Reactions id={post.id} bind:reactions={post.reactions} />
      <div class="actions">
        {#if myAcct === post.author.acct}
          <button type="button" class="linklike" onclick={() => post && startEdit(post)}
            >{t().postDetail.edit}</button
          >
          <button type="button" class="linklike" onclick={() => post && askDelete(post.id)}
            >{t().postDetail.delete}</button
          >
        {/if}
      </div>
    {/if}
  </article>

  {#if post.replies && post.replies.length > 0}
    <ul class="list">
      {#each post.replies as r (r.id)}
        <li class="reply">
          {#if editingId === r.id}
            {@render editForm(r, false)}
          {:else if deletingId === r.id}
            {@render deleteConfirm(r, false)}
          {:else}
            <p>
              <Author author={r.author} at={when(r.created_at)} />
              {#if r.local_only}<span class="local-badge">{t().visibility.badge}</span>{/if}
            </p>
            <div class="body">{@html renderEmojis(localized(r.content_html, r.content_html_i18n), r.emojis)}</div>
            <Reactions id={r.id} bind:reactions={r.reactions} />
            <div class="actions">
              {#if myAcct === r.author.acct}
                <button type="button" class="linklike" onclick={() => startEdit(r)}>{t().postDetail.edit}</button>
                <button type="button" class="linklike" onclick={() => askDelete(r.id)}
                  >{t().postDetail.delete}</button
                >
              {/if}
            </div>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}

  {#if signedIn()}
    <form class="card write" onsubmit={reply}>
      <LangTabs bind:active={replyLang} />
      <VisibilityPicker bind:active={visibility} />
      {#if replyLang === 'ja'}
        <MarkdownToolbar bind:value={text} el={textEl} />
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
        <MarkdownToolbar bind:value={textKo} el={textElKo} />
        <textarea
          class="body-input"
          bind:value={textKo}
          bind:this={textElKo}
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
     ここだけ margin は 0 のまま。ここは投稿の題(書いた人が決める、
     可変の文字)なので、全体ルールの丸ゴシックには乗らず本文と同じ
     BIZ UDP に戻す。 */
  h1 {
    font-size: 1.4rem;
    margin: 0;
    font-family: inherit;
  }

  /* カードで囲むと箱がもう一枚増えて、.measure の余白と重なって窮屈に
     見えていた ── スレッドは上から下へ読むだけの一続きの流れなので、
     箱に区切らず、罫線一本で分ける(掲示板・コメント欄の型)。 */
  .post-body {
    padding-bottom: 1.25rem;
    border-bottom: 1px solid var(--line);
  }

  .head {
    margin-bottom: 1.25rem;
  }

  .local-badge {
    font-size: 0.72rem;
    color: var(--ink-soft);
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 0.1rem 0.55rem;
    margin-left: 0.4rem;
  }

  /* 見た目の文字は小さいままで、タップできる範囲だけ 44px 確保する
     ── 上下に margin をマイナスして、見た目の余白は増やさない
     (モバイルで実際に押せなかった、との報告で気づいた)。 */
  .linklike {
    display: inline-flex;
    align-items: center;
    min-height: 2.75rem;
    margin: -0.7rem 0;
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

  .actions {
    display: flex;
    align-items: center;
    gap: 1.2rem;
    margin-top: 0.6rem;
  }

  .head p {
    margin: 0.4rem 0 0;
  }

  .list {
    list-style: none;
    margin: 0;
    padding: 0;
  }

  .reply {
    padding: 1rem 0 1rem 0.9rem;
    border-left: 2px solid var(--line);
    border-bottom: 1px solid var(--line);
  }

  .reply:last-child {
    border-bottom: none;
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

  .write textarea,
  .edit-form textarea {
    width: 100%;
  }

  .body-input {
    resize: none;
    overflow: hidden;
    line-height: 1.9;
  }

  .edit-form {
    display: grid;
    gap: 0.6rem;
  }

  .edit-form input[type='text'] {
    font-family: inherit;
  }

  .secondary-label {
    display: grid;
    gap: 0.3rem;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 0.6rem;
  }

  .ghost {
    background: transparent;
  }

  .error {
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
  }

  .confirm-delete {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.5rem 0.9rem;
    margin: 0;
    color: var(--ink-soft);
  }
</style>
