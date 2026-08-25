<script lang="ts">
  import { page } from '$app/state';
  import {
    getDeco,
    listPosts,
    listFlow,
    seenDeco,
    setDecoNotify,
    setDecoTopic,
    when as fmt,
    type DecoNotify,
    startOfToday,
    signedIn,
    when,
    localized,
    type Deco,
    type Post
  } from '$lib/api';
  import { t } from '$lib/i18n.svelte';
  import Author from '$lib/Author.svelte';
  import Flow from '$lib/Flow.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  const slug = $derived(page.params.slug ?? '');

  let deco = $state<Deco | null>(null);
  let posts = $state<Post[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let done = $state(false);

  // いま話していること。題を一件ずつに背負わせる代わりに、場が一本
  // 持つ ── 話が流れたら、居る人の誰かが書き換える。
  //
  // 誰が変えたかを一緒に出すのは、それが抑止だから。板の顔になる一行を
  // 黙って書き換えられる形にはしない。
  let editingTopic = $state(false);
  let topicDraft = $state('');
  let topicError = $state(false);

  function startTopic() {
    topicDraft = deco?.topic ?? '';
    topicError = false;
    editingTopic = true;
  }

  async function saveTopic() {
    if (!deco) return;
    try {
      deco = await setDecoTopic(slug, topicDraft);
      editingTopic = false;
    } catch {
      // 通りすがりは変えられない（サーバが 403）。断られたことだけ出す。
      topicError = true;
    }
  }

  // この板をどう知らせてほしいか。一覧にボタンを置かず、板の中に
  // 畳んで置く ── 既定のままで困らない人がほとんどなので、開くまでは
  // 目に入らなくていい。
  let showPrefs = $state(false);
  let notify = $state<DecoNotify>('participating');

  async function pick(v: DecoNotify) {
    const prev = notify;
    notify = v;
    try {
      await setDecoNotify(slug, v);
    } catch {
      notify = prev;
    }
  }

  // 話す板は、まず今日のぶんだけ。境目は読む人の時計で決まる。
  // 流れる板でも、終わらない川にはしない ── 今日を読み切ったら
  // そこで一度終わって、その先は自分で「読む」を押す。
  let talk = $derived(deco?.kind === 'talk');
  let atToday = $state(true);

  $effect(() => {
    const s = slug;
    loading = true;
    done = false;
    atToday = true;

    getDeco(s)
      .then(async (d) => {
        deco = d;
        notify = d.notify;
        if (d.kind === 'talk') {
          const rows = await listFlow(s, { since: startOfToday() });
          posts = rows;
        } else {
          const p = await listPosts(s);
          posts = p;
          done = p.length < 30;
        }
      })
      .catch(() => (error = t().board.notFound))
      .finally(() => (loading = false));

    // 開いたら、ここまで見たことにする ── 一覧の光りが消える。
    // 入っていない板に投げても害は無い（読んだ位置が一点付くだけ）。
    if (signedIn()) void seenDeco(s).catch(() => {});
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

  // 話す板で、今日より前へ。押した時点で「今日で終わる」を降りるので、
  // そこから先はふつうの「もっと読む」になる。
  async function earlier() {
    const last = posts.at(-1);
    const rows = await listFlow(slug, { beforeId: last?.id });
    posts = [...posts, ...rows];
    atToday = false;
    if (rows.length === 0) done = true;
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

  <div class="topic">
    {#if editingTopic}
      <input
        type="text"
        bind:value={topicDraft}
        maxlength="120"
        placeholder={t().topic.set}
        onkeydown={(e) => e.key === 'Enter' && saveTopic()}
      />
      <button class="linklike" type="button" onclick={saveTopic}>{t().topic.save}</button>
      <button class="linklike" type="button" onclick={() => (editingTopic = false)}
        >{t().topic.cancel}</button
      >
    {:else if deco.topic}
      <p>
        <span class="muted small">{t().topic.now}</span>
        <span class="line">{deco.topic}</span>
        {#if deco.topic_by}
          <span class="muted small"
            >{t().topic.by(deco.topic_by.display_name)}{deco.topic_at
              ? ` · ${fmt(deco.topic_at)}`
              : ''}</span
          >
        {/if}
        {#if signedIn()}
          <button class="linklike small" type="button" onclick={startTopic}>{t().topic.edit}</button>
        {/if}
      </p>
    {:else if signedIn()}
      <button class="linklike muted small" type="button" onclick={startTopic}>{t().topic.set}</button>
    {/if}
    {#if topicError}<p class="error small">{t().postDetail.error}</p>{/if}
  </div>

  {#if !signedIn()}
    <p class="muted">
      {t().board.readOnly.prefix}<a href="/login?next=/d/{slug}/new">{t().board.readOnly.link}</a
      >{t().board.readOnly.suffix}
    </p>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}

  {#if talk}
    {#if posts.length === 0}
      <p class="muted empty">{t().flow.empty}</p>
    {:else}
      <Flow bind:rows={posts} />
    {/if}

    {#if done}
      <p class="muted end">{t().board.end}</p>
    {:else if atToday}
      <p class="muted end">{t().flow.endToday}</p>
      <button class="btn" type="button" onclick={earlier}>{t().flow.earlier}</button>
    {:else}
      <button class="btn" type="button" onclick={earlier}>{t().board.more}</button>
    {/if}
  {:else if posts.length === 0}
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
              <td data-label={t().board.colAuthor}><Author author={post.author} compact /></td>
              <td class="date muted" data-label={t().board.colDate}>{when(post.created_at)}</td>
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

  {#if signedIn()}
    <details class="prefs" bind:open={showPrefs}>
      <summary class="muted small">{t().mine.notify}</summary>
      <div class="picks">
        {#each [['participating', t().mine.participating], ['all', t().mine.all], ['quiet', t().mine.quiet]] as [value, label] (value)}
          <label class="pick">
            <input
              type="radio"
              name="notify"
              checked={notify === value}
              onchange={() => pick(value as DecoNotify)}
            />
            <span>{label}</span>
          </label>
        {/each}
      </div>
    </details>
  {/if}

  <p class="back"><a href="/">{t().common.toDecoList}</a></p>
{/if}

<style>
  /* 板の名前のすぐ下。一件ずつの題ではなく、場が持つ一行。 */
  .topic {
    margin: -0.4rem 0 1rem;
  }

  .topic p {
    margin: 0;
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 0.45rem;
  }

  .topic .line {
    font-weight: 600;
  }

  .topic input {
    width: 100%;
    margin-bottom: 0.4rem;
  }

  /* 板の下、戻る道の手前。読みに来た人の邪魔をしない位置に畳んでおく。 */
  .prefs {
    margin-top: 2rem;
    border-top: 1px solid var(--line);
    padding-top: 0.8rem;
  }

  .prefs summary {
    cursor: pointer;
  }

  .picks {
    display: grid;
    gap: 0.4rem;
    margin-top: 0.6rem;
  }

  .pick {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .pick input {
    width: auto;
    min-width: 0;
  }

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

  /* 狭い画面では、表のまま横スクロールさせず、行を一枚のカードに
     組み直す ── 番号だけ落として残りを詰める、では欄が横に長いまま
     窮屈だった。見出し行は隠して、その代わり著者・日付の欄の頭に
     `data-label`(見出しと同じ文字)を出す ── 情報はデスクトップと
     同じだけ残す。 */
  @media (max-width: 640px) {
    .board-table thead {
      display: none;
    }

    .board-table,
    .board-table tbody,
    .board-table tr,
    .board-table td {
      display: block;
      width: 100%;
    }

    .board-table tr {
      padding: 0.7rem 0;
      border-bottom: 1px solid var(--line);
    }

    .board-table td {
      padding: 0.15rem 0;
      border-bottom: none;
    }

    .board-table td.num {
      display: none;
    }

    .board-table td[data-label]::before {
      content: attr(data-label);
      display: inline-block;
      min-width: 3.5em;
      color: var(--ink-soft);
      font-size: 0.78rem;
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
