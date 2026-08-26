<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { getDeco, createPost, signedIn, localized, type Deco, type Visibility } from '$lib/api';
  import { autoresize, submitOnMetaEnter } from '$lib/textarea';
  import { loadDraft, saveDraft, clearDraft, hasSeenComposeTip, markComposeTipSeen } from '$lib/composeDraft';
  import { t, getLang } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';
  import LangTabs from '$lib/LangTabs.svelte';
  import VisibilityPicker from '$lib/VisibilityPicker.svelte';
  import MarkdownToolbar from '$lib/MarkdownToolbar.svelte';

  const slug = $derived(page.params.slug ?? '');

  let deco = $state<Deco | null>(null);
  let loading = $state(true);
  let notFound = $state(false);

  let title = $state('');
  let text = $state('');
  let titleKo = $state('');
  let textKo = $state('');
  let lang = $state<'ja' | 'ko'>(getLang());
  // 選ばれていないあいだは、この板がふつうどちらで書くか。
  // 一件ごとに訊かれ続けないための出発点で、選び直せる。
  let visibility = $state<Visibility>('public');
  let posting = $state(false);
  let error = $state<string | null>(null);

  let textEl = $state<HTMLTextAreaElement | null>(null);
  let textElKo = $state<HTMLTextAreaElement | null>(null);

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
      titleKo = draft.titleKo ?? '';
      textKo = draft.textKo ?? '';
    }

    showTip = !hasSeenComposeTip();
    markComposeTipSeen();

    getDeco(s)
      .then((d) => {
        deco = d;
        visibility = d.local_only ? 'local' : 'public';
      })
      .catch(() => (notFound = true))
      .finally(() => (loading = false));
  });

  // 打つたびに、そのまま下書きへ。書きかけを失くさないように。
  $effect(() => {
    if (slug) saveDraft(slug, { title, text, titleKo, textKo });
  });

  // どちらの言語で書いてもいい ── 日本語欄が必須、ではない。埋まって
  // いるほうがそのまま主(連合される側)になる。両方埋めれば、片方が
  // もう一方に添えられる。
  // 話す板では、ひとこと置くのに見出しを考えさせない ── 欄そのものを
  // 出さないので、埋まっているかも問わない。
  const talk = $derived(deco?.kind === 'talk');

  // 長い文章として出すか。既定は Note ── 外でも本文がそのまま読める。
  // 選ぶと Article になって、外では題と書き出しとリンクだけになる。
  // 話す板には題が無いので、この選択も出さない。
  let asArticle = $state(false);
  const jaComplete = $derived(talk ? !!text.trim() : !!title.trim() && !!text.trim());
  const koComplete = $derived(talk ? !!textKo.trim() : !!titleKo.trim() && !!textKo.trim());
  const canSubmit = $derived(jaComplete || koComplete);

  async function write(e: SubmitEvent) {
    e.preventDefault();
    if (!canSubmit || posting) return;
    posting = true;
    error = null;
    try {
      const made = await createPost(
        slug,
        jaComplete
          ? {
              title: title.trim(),
              status: text,
              title_i18n: koComplete ? { ko: titleKo.trim() } : undefined,
              content_i18n: koComplete ? { ko: textKo.trim() } : undefined,
              visibility,
              as_article: asArticle
            }
          : { title: titleKo.trim(), status: textKo, visibility, as_article: asArticle }
      );
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
  <PageHeader title={t().newPost.title(localized(deco.name, deco.name_i18n))} />

  {#if showTip}
    <p class="tip">
      {t().newPost.tip}
      <button type="button" class="linklike" onclick={() => (showTip = false)}>{t().newPost.tipClose}</button>
    </p>
  {/if}

  <form class="card stack" onsubmit={write}>
    <LangTabs bind:active={lang} />
    <VisibilityPicker bind:active={visibility} />

    {#if !talk}
      <label class="check">
        <input type="checkbox" bind:checked={asArticle} />
        <span>
          {t().article.label}
          <span class="muted small">{t().article.hint}</span>
        </span>
      </label>
    {/if}

    {#if lang === 'ja'}
      {#if !talk}
        <label>
          <span class="muted">{t().newPost.fieldTitle}</span>
          <input type="text" bind:value={title} maxlength="120" autofocus />
        </label>
      {/if}
      <label>
        <span class="muted">{t().newPost.fieldBody}</span>
        <MarkdownToolbar bind:value={text} el={textEl} />
        <textarea
          class="body-input"
          bind:value={text}
          bind:this={textEl}
          rows="6"
          placeholder={t().newPost.bodyPlaceholder}
          use:autoresize
          use:submitOnMetaEnter
        ></textarea>
        <span class="muted small">
          {t().newPost.formatHint}
        </span>
      </label>
    {:else}
      {#if !talk}
        <label>
          <span class="muted">{t().newPost.fieldTitle}</span>
          <input type="text" bind:value={titleKo} maxlength="120" />
        </label>
      {/if}
      <label>
        <span class="muted">{t().newPost.fieldBody}</span>
        <MarkdownToolbar bind:value={textKo} el={textElKo} />
        <textarea
          class="body-input"
          bind:value={textKo}
          bind:this={textElKo}
          rows="6"
          placeholder={t().newPost.bodyPlaceholder}
        ></textarea>
        <span class="muted small">
          {t().newPost.formatHint}
        </span>
      </label>
    {/if}

    <div class="row">
      <button class="btn" type="submit" disabled={posting || !canSubmit}
        >{posting ? t().newPost.submitting : t().newPost.submit}</button
      >
      <span class="muted">{t().newPost.postedAs}</span>
    </div>
    {#if !canSubmit && (title.trim() || text.trim() || titleKo.trim() || textKo.trim())}
      <p class="muted small">{t().newPost.needOneLang}</p>
    {/if}
  </form>

  {#if error}<p class="error">{error}</p>{/if}

  <p class="back"><a href="/d/{slug}">{t().newPost.back(localized(deco.name, deco.name_i18n))}</a></p>
{/if}

<style>
  /* 印と言葉が横に、説明は下に。選ぶのは一度きりなので、説明を
     選択肢の中に置く ── 別に注釈を出すと、どちらの話か目で追うことになる。 */
  .check {
    display: flex;
    align-items: start;
    gap: 0.5rem;
  }

  .check input {
    width: auto;
    min-width: 0;
    margin-top: 0.25rem;
  }

  .check span span {
    display: block;
  }

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
