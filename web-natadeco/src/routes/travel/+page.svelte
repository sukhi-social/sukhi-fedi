<script lang="ts">
  import { page } from '$app/state';
  import { listFlow, listDecoTags, signedIn, when, localized, type DecoTag, type Post } from '$lib/api';
  import { TRAVEL_SLUG } from '$lib/site';
  import { renderEmojis } from '$lib/emoji';
  import { t } from '$lib/i18n.svelte';
  import Author from '$lib/Author.svelte';
  import Reactions from '$lib/Reactions.svelte';
  import PageHeader from '$lib/PageHeader.svelte';
  import type { PageProps } from './$types';

  let { data }: PageProps = $props();

  const tag = $derived(page.url.searchParams.get('tag'));

  // 流れには返事も混ざる。ここは記録だけを並べる ── 返事は一枚の頁で読める。
  const records = (rows: Post[]) => rows.filter((r) => !r.in_reply_to_ap_id);

  // svelte-ignore state_referenced_locally
  let rows = $state<Post[]>(records(data.rows));
  // svelte-ignore state_referenced_locally
  let tags = $state<DecoTag[]>(data.tags);
  // svelte-ignore state_referenced_locally
  let done = $state(data.rows.length < 40);
  // svelte-ignore state_referenced_locally
  let missing = $state(!data.deco);

  // ブラウザで取り直す ── 入っている人の反応の me は、サーバが知らない。
  async function reload(g: string | null) {
    try {
      const fresh = await listFlow(TRAVEL_SLUG, { tag: g });
      rows = records(fresh);
      done = fresh.length < 40;
      missing = false;
    } catch {
      /* サーバが描いた分をそのまま */
    }
    listDecoTags(TRAVEL_SLUG)
      .then((r) => (tags = r))
      .catch(() => {});
  }

  $effect(() => {
    const g = tag;
    rows = records(data.rows);
    tags = data.tags;
    done = data.rows.length < 40;
    missing = !data.deco;
    if (!data.deco || (data.anonymous && signedIn())) void reload(g);
  });

  // 「もっと読む」。終わりのないスクロールにはしない。
  let last = $state<number | null>(null);
  async function more() {
    const cursor = last ?? rows.at(-1)?.id;
    if (!cursor) return;
    const next = await listFlow(TRAVEL_SLUG, { beforeId: cursor, tag });
    last = next.at(-1)?.id ?? cursor;
    rows = [...rows, ...records(next)];
    if (next.length < 40) done = true;
  }

  const hasPlaces = $derived(rows.some((r) => r.place));
</script>

<!-- 題は板の名前(admin が付けたもの)。玄関の一行は、ひなたのことば。 -->
<PageHeader
  title={data.deco ? localized(data.deco.name, data.deco.name_i18n) : t().travel.title}
  subtitle={t().travel.entrance}
>
  {#snippet actions()}
    {#if signedIn()}
      <a class="btn" href="/new">{t().travel.write}</a>
    {/if}
  {/snippet}
</PageHeader>

{#if !signedIn()}
  <p class="muted">
    {t().travel.readOnly.prefix}<a href="/login?next=/new">{t().travel.readOnly.link}</a>{t().travel.readOnly.suffix}
  </p>
{/if}

{#if missing}
  <p class="muted">{t().travel.notReady}</p>
{:else}
  <nav class="shelf" aria-label="tags">
    {#if hasPlaces || tags.length > 0}
      <a class="chip" class:on={!tag} href="/">{t().board.allTags}</a>
    {/if}
    {#each tags as tg (tg.name)}
      <a class="chip" class:on={tag === tg.name} href="/?tag={encodeURIComponent(tg.name)}"
        >#{tg.name}<span class="muted count">{tg.count}</span></a
      >
    {/each}
    <a class="chip map" href="/map">{t().travel.toMap}</a>
  </nav>

  {#if rows.length === 0}
    <p class="muted empty">{tag ? t().board.tagEmpty(tag) : t().travel.empty}</p>
  {:else}
    <ol class="records">
      {#each rows as row, i (row.id)}
        <li class="card record">
          <Author author={row.author} at={when(row.created_at)} />
          {#if row.title}
            <h2 class="record-title"><a href="/posts/{row.id}">{localized(row.title, row.title_i18n)}</a></h2>
          {/if}
          <div class="body">
            {@html renderEmojis(localized(row.content_html, row.content_html_i18n), row.emojis)}
          </div>
          <div class="foot">
            {#if row.place}
              <a class="place" href="/map#{row.id}">{row.place.name || t().travel.somewhere}</a>
            {/if}
            <a class="muted small" href="/posts/{row.id}"
              >{row.reply_count > 0 ? t().travel.replies(row.reply_count) : t().travel.open}</a
            >
          </div>
          <Reactions id={row.id} bind:reactions={rows[i].reactions} />
        </li>
      {/each}
    </ol>

    {#if done}
      <p class="muted end">{t().board.end}</p>
    {:else}
      <button class="btn" type="button" onclick={more}>{t().board.more}</button>
    {/if}
  {/if}
{/if}

<style>
  .shelf {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin-bottom: 1.25rem;
  }

  .chip {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    min-height: 2rem;
    padding: 0.2rem 0.75rem;
    border: 1px solid var(--line);
    border-radius: 999px;
    font-size: 0.85rem;
    text-decoration: none;
    color: var(--ink-soft);
  }

  .chip.on {
    background: var(--sun-soft);
    color: var(--ink);
    border-color: transparent;
  }

  .chip.map {
    margin-left: auto;
  }

  .chip .count {
    font-size: 0.75rem;
  }

  .records {
    list-style: none;
    padding: 0;
    margin: 0;
    display: grid;
    gap: 1rem;
  }

  .record {
    display: grid;
    gap: 0.6rem;
  }

  .record-title {
    margin: 0;
    font-size: 1.05rem;
    font-family: var(--font-round);
  }

  .record-title a {
    text-decoration: none;
  }

  .body :global(p) {
    margin: 0 0 0.5rem;
  }

  .body :global(p:last-child) {
    margin-bottom: 0;
  }

  .foot {
    display: flex;
    align-items: center;
    gap: 0.9rem;
  }

  /* 場所の名前。地図へ続く、小さな印。 */
  .place {
    font-size: 0.85rem;
    color: var(--ink-soft);
    text-decoration: none;
    border-bottom: 1px dotted var(--sun);
  }

  .place::before {
    content: '◎ ';
    color: var(--sun);
  }

  .empty,
  .end {
    margin: 2rem 0;
    text-align: center;
  }
</style>
