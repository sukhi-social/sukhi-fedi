<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { getDeco, createPost, signedIn, type Deco } from '$lib/api';
  import { autoresize, submitOnMetaEnter } from '$lib/textarea';
  import { loadDraft, saveDraft, clearDraft, hasSeenComposeTip, markComposeTipSeen } from '$lib/composeDraft';
  import { t } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  const slug = $derived(page.params.slug ?? '');

  let deco = $state<Deco | null>(null);
  let loading = $state(true);
  let notFound = $state(false);

  let title = $state('');
  let text = $state('');
  let posting = $state(false);
  let error = $state<string | null>(null);

  let showTip = $state(false);

  $effect(() => {
    if (!signedIn()) {
      void goto(`/login?next=/d/${slug}/new`);
      return;
    }
    const s = slug;
    loading = true;

    const draft = loadDraft(s);
    if (draft) {
      title = draft.title;
      text = draft.text;
    }

    showTip = !hasSeenComposeTip();
    markComposeTipSeen();

    getDeco(s)
      .then((d) => (deco = d))
      .catch(() => (notFound = true))
      .finally(() => (loading = false));
  });

  // 打つたびに、そのまま下書きへ。書きかけを失くさないように。
  $effect(() => {
    if (slug) saveDraft(slug, { title, text });
  });

  async function write(e: SubmitEvent) {
    e.preventDefault();
    if (!title.trim() || !text.trim() || posting) return;
    posting = true;
    error = null;
    try {
      const made = await createPost(slug, { title: title.trim(), status: text });
      clearDraft(slug);
      await goto(`/posts/${made.id}`);
    } catch {
      error = t().newPost.error;
      posting = false;
    }
  }
</script>

{#if loading}
  <p class="muted">{t().common.loading}</p>
{:else if notFound || !deco}
  <p class="muted">{t().newPost.notFound}</p>
  <p><a href="/">{t().common.toDecoList}</a></p>
{:else}
  <PageHeader title={t().newPost.title(deco.name)} />

  {#if showTip}
    <p class="tip">
      {t().newPost.tip}
      <button type="button" class="linklike" onclick={() => (showTip = false)}>{t().newPost.tipClose}</button>
    </p>
  {/if}

  <form class="card stack" onsubmit={write}>
    <label>
      <span class="muted">{t().newPost.fieldTitle}</span>
      <input type="text" bind:value={title} required maxlength="120" autofocus />
    </label>
    <label>
      <span class="muted">{t().newPost.fieldBody}</span>
      <textarea
        class="body-input"
        bind:value={text}
        rows="6"
        placeholder={t().newPost.bodyPlaceholder}
        use:autoresize
        use:submitOnMetaEnter
      ></textarea>
      <span class="muted small">
        {t().newPost.formatHint}
      </span>
    </label>
    <div class="row">
      <button class="btn" type="submit" disabled={posting || !title.trim() || !text.trim()}
        >{posting ? t().newPost.submitting : t().newPost.submit}</button
      >
      <span class="muted">{t().newPost.postedAs}</span>
    </div>
  </form>

  {#if error}<p class="error">{error}</p>{/if}

  <p class="back"><a href="/d/{slug}">{t().newPost.back(deco.name)}</a></p>
{/if}

<style>
  .stack {
    display: grid;
    gap: 0.85rem;
    max-width: 32rem;
  }

  label {
    display: grid;
    gap: 0.3rem;
  }

  /* 一度だけの、控えめなヒント。カードより静かな色味にして、
     本体の書式(warm な pill ボタン等)とは張り合わない。 */
  .tip {
    display: flex;
    align-items: baseline;
    gap: 0.6rem;
    flex-wrap: wrap;
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
    margin-bottom: 1rem;
    font-size: 0.85rem;
  }

  .linklike {
    background: none;
    border: none;
    padding: 0;
    color: inherit;
    text-decoration: underline;
    cursor: pointer;
    font: inherit;
  }

  /* 打った分だけ伸びる本文欄。伸びても読みやすいよう、行間を広めに。 */
  .body-input {
    resize: none;
    overflow: hidden;
    min-height: 9rem;
    line-height: 1.9;
  }

  .small {
    font-size: 0.78rem;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 0.8rem;
    flex-wrap: wrap;
  }

  .error {
    margin-top: 1rem;
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
  }

  .back {
    margin-top: 1.75rem;
  }
</style>
