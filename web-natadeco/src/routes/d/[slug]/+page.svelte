<script lang="ts">
  import { page } from '$app/state';
  import {
    getDeco,
    listPosts,
    listFlow,
    listDecoTags,
    renameDeco,
    seenDeco,
    setDecoNotify,
    getCurrentAccount,
    type DecoNotify,
    type DecoTag,
    startOfToday,
    signedIn,
    when,
    localized,
    type Deco,
    type Post
  } from '$lib/api';
  import { t, getLang } from '$lib/i18n.svelte';
  import Author from '$lib/Author.svelte';
  import Flow from '$lib/Flow.svelte';
  import PageHeader from '$lib/PageHeader.svelte';
  import LangTabs from '$lib/LangTabs.svelte';
  import type { PageProps } from './$types';

  let { data }: PageProps = $props();

  const slug = $derived(page.params.slug ?? '');
  // いま絞っている #タグ。URL に持たせるので、貼って渡せるし、戻るで戻れる。
  const tag = $derived(page.url.searchParams.get('tag'));

  // この板で使われている #タグ。誰かが決めて置くカテゴリではなく、
  // 書かれたタグがそのまま棚になる ── だから作る欄も消す欄も無い。
  // svelte-ignore state_referenced_locally
  let tags = $state<DecoTag[]>(data.tags);

  // 板の名前を変えられるのは admin だけ(立てる・畳むと同じ口)。
  let isAdmin = $state(false);
  let renaming = $state(false);
  let name = $state('');
  let nameKo = $state('');
  let lang = $state<'ja' | 'ko'>(getLang());
  let saving = $state(false);
  let renameError = $state<string | null>(null);

  // `name` は立てた人が実際に書いた言語で、`name_i18n` にもう一方が
  // 添えてある。ja が添えてあれば主は韓国語、そうでなければ主は日本語。
  function startRename() {
    if (!deco) return;
    if (deco.name_i18n.ja) {
      name = deco.name_i18n.ja;
      nameKo = deco.name;
    } else {
      name = deco.name;
      nameKo = deco.name_i18n.ko ?? '';
    }
    lang = getLang();
    renameError = null;
    renaming = true;
  }

  // 主になるのは、埋まっているほうの名前。両方あれば表示言語のほうを
  // 主にして、もう一方を添える(立てるときと同じ決めかた)。
  async function confirmRename(e: SubmitEvent) {
    e.preventDefault();
    const ja = name.trim();
    const ko = nameKo.trim();
    if (saving || !(ja || ko)) return;
    saving = true;
    renameError = null;
    try {
      deco = await renameDeco(
        slug,
        ja
          ? { name: ja, name_i18n: ko ? { ko } : {} }
          : { name: ko, name_i18n: {} }
      );
      renaming = false;
    } catch {
      renameError = t().board.renameError;
    } finally {
      saving = false;
    }
  }

  // 最初の一枚は load が持ってくる(サーバでも描ける)。
  // svelte-ignore state_referenced_locally
  let deco = $state<Deco | null>(data.deco);
  // svelte-ignore state_referenced_locally
  let posts = $state<Post[]>(data.posts);
  let loading = $state(false);
  // svelte-ignore state_referenced_locally
  let error = $state<string | null>(data.deco ? null : t().board.notFound);
  // svelte-ignore state_referenced_locally
  let done = $state(data.deco?.kind !== 'talk' && data.posts.length < 30);

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

  // ブラウザで取り直す ── サーバは匿名で描いたので、入っている人の
  // 印(notify・反応の me)と、話す板の「今日」(読む人の時計)はここで。
  async function reload(s: string, g: string | null) {
    loading = true;
    try {
      const d = await getDeco(s);
      deco = d;
      notify = d.notify;
      if (d.kind === 'talk') {
        posts = await listFlow(s, { since: startOfToday(), tag: g });
      } else {
        const p = await listPosts(s, undefined, g);
        posts = p;
        done = p.length < 30;
      }
      error = null;
    } catch {
      error = t().board.notFound;
    } finally {
      loading = false;
    }
    listDecoTags(s)
      .then((rows) => (tags = rows))
      .catch(() => {});
  }

  $effect(() => {
    const s = slug;
    const g = tag;
    deco = data.deco;
    posts = data.posts;
    tags = data.tags;
    notify = data.deco?.notify ?? 'participating';
    error = data.deco ? null : t().board.notFound;
    done = data.deco?.kind !== 'talk' && data.posts.length < 30;
    atToday = true;

    const talkFromServer = data.anonymous && data.deco?.kind === 'talk';
    if (!data.deco || talkFromServer || (data.anonymous && signedIn())) void reload(s, g);

    // 開いたら、ここまで見たことにする ── 一覧の光りが消える。
    // 入っていない板に投げても害は無い（読んだ位置が一点付くだけ）。
    if (signedIn()) void seenDeco(s).catch(() => {});
    if (signedIn()) getCurrentAccount().then((a) => (isAdmin = a?.isAdmin ?? false));
  });

  // 「もっと読む」。終わりのないスクロールにはしない ── 読み終えた、
  // という感じが持てるほうがいい。
  async function more() {
    const last = posts.at(-1);
    if (!last) return;
    const next = await listPosts(slug, last.id, tag);
    posts = [...posts, ...next];
    if (next.length === 0) done = true;
  }

  // 話す板で、今日より前へ。押した時点で「今日で終わる」を降りるので、
  // そこから先はふつうの「もっと読む」になる。
  async function earlier() {
    const last = posts.at(-1);
    const rows = await listFlow(slug, { beforeId: last?.id, tag });
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

  {#if !signedIn()}
    <p class="muted">
      {t().board.readOnly.prefix}<a href="/login?next=/d/{slug}/new">{t().board.readOnly.link}</a
      >{t().board.readOnly.suffix}
    </p>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}

  {#if tags.length > 0}
    <!-- 棚。書かれた #タグ がそのまま並ぶ。押すと、その話だけになる。 -->
    <nav class="tags" aria-label="tags">
      <a class="chip" class:on={!tag} href="/d/{slug}">{t().board.allTags}</a>
      {#each tags as tg (tg.name)}
        <a class="chip" class:on={tag === tg.name} href="/d/{slug}?tag={encodeURIComponent(tg.name)}"
          >#{tg.name}<span class="muted count">{tg.count}</span></a
        >
      {/each}
    </nav>
  {/if}

  {#if talk}
    {#if posts.length === 0}
      <p class="muted empty">{tag ? t().board.tagEmpty(tag) : t().flow.empty}</p>
    {:else}
      <Flow bind:rows={posts} {slug} />
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
    <p class="muted empty">{tag ? t().board.tagEmpty(tag) : t().board.empty}</p>
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
                {#each post.tags as tg (tg)}
                  <a class="tag muted" href="/d/{slug}?tag={encodeURIComponent(tg)}">#{tg}</a>
                {/each}
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

  {#if isAdmin}
    <details class="prefs" open={renaming} ontoggle={(e) => (renaming = e.currentTarget.open) && startRename()}>
      <summary class="muted small">{t().board.rename}</summary>
      {#if renaming}
        <form class="rename" onsubmit={confirmRename}>
          <LangTabs bind:active={lang} />
          {#if lang === 'ja'}
            <label>
              <span class="muted">{t().home.fields.name}</span>
              <input type="text" bind:value={name} maxlength="60" />
            </label>
          {:else}
            <label>
              <span class="muted">{t().home.fields.name}</span>
              <input type="text" bind:value={nameKo} maxlength="60" />
            </label>
          {/if}
          <div class="row">
            <button class="btn" type="submit" disabled={saving || !(name.trim() || nameKo.trim())}>
              {saving ? t().board.renameSaving : t().board.renameSave}
            </button>
          </div>
          {#if renameError}<p class="error">{renameError}</p>{/if}
        </form>
      {/if}
    </details>
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

  /* 棚。横に並べて、はみ出したら折り返す。押せるものは丸く。 */
  .tags {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin: 0 0 1rem;
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

  .chip .count {
    font-size: 0.75rem;
  }

  /* 題の横に添える印。押すと、その棚へ。 */
  .tag {
    margin-left: 0.4rem;
    font-size: 0.8rem;
    text-decoration: none;
    white-space: nowrap;
  }

  .rename {
    display: grid;
    gap: 0.85rem;
    max-width: 32rem;
    margin-top: 0.6rem;
  }

  .rename label {
    display: grid;
    gap: 0.3rem;
  }

  .rename .row {
    display: flex;
    align-items: center;
    gap: 0.8rem;
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
