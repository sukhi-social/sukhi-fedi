<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { fetchTimeline, type Status, type TimelineKind } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { autoRetry, isConnectivityError } from '$lib/connection';
  import { composeRequest } from '$lib/compose';
  import StatusCard from '$lib/components/Status.svelte';
  import Composer from '$lib/components/Composer.svelte';
  import TimelineFilter from '$lib/components/TimelineFilter.svelte';
  import { t, locale } from '$lib/i18n';
  import { startTimelineStream } from '$lib/webtransport';

  // フィードのいちばん下のフッター用。ja は素の /terms /privacy、ko は
  // ?lang=ko を付ける。signup と同じ作りだが、こちらは signup=true を付け
  // ない ── ただ読むためのリンクなので。
  const termsHref = $derived($locale === 'ko' ? '/terms?lang=ko' : '/terms');
  const privacyHref = $derived($locale === 'ko' ? '/privacy?lang=ko' : '/privacy');

  let replyTo = $state<Status | null>(null);
  let quoteOf = $state<Status | null>(null);
  let composerOpen = $state(false);

  function openCompose() {
    replyTo = null;
    quoteOf = null;
    composerOpen = true;
  }

  // ヘッダーの「書く」から。開いたら 0 に戻す(戻さないと、あとで
  // このページに来直したときにまた開いてしまう)。
  $effect(() => {
    if ($composeRequest > 0) {
      composeRequest.set(0);
      openCompose();
    }
  });

  function onReply(s: Status) {
    replyTo = s;
    quoteOf = null;
    composerOpen = true;
    // 上に composer があるのでスクロール。
    if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function onQuote(s: Status) {
    quoteOf = s;
    replyTo = null;
    composerOpen = true;
    if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function onPosted(s: Status) {
    // home / public のときは先頭に挿す。tag のときは混ぜずに閉じるだけ。
    if (kind === 'home' || kind === 'public') {
      items = [s, ...items];
    }
    composerOpen = false;
    replyTo = null;
    quoteOf = null;
  }

  function onCancel() {
    composerOpen = false;
    replyTo = null;
    quoteOf = null;
  }

  function onDelete(s: Status) {
    items = items.filter((it) => it.id !== s.id);
  }

  let kind = $state<TimelineKind>('home');
  let tag = $state('');
  let pendingTag = $state('');

  let items = $state<Status[]>([]);
  // WebTransport の live 新着はここに溜め、「新着 N 件」で明示的に見せる（calm-UX。
  // 勝手に頭へ差し込まない）。home のときだけ ── karutte が押す feed は local+user＝
  // まさにホームの構成なので、それを live で受ける。
  let incoming = $state<Status[]>([]);
  let nextMaxId = $state<string | null>(null);
  let loading = $state(false);
  let error = $state<string | null>(null);
  // 「繋がらなくて失敗した」状態。エラー文ではなく静かな待ち表示を出し、
  // つながりが戻ったら自動で読み直す(retry が裏で叩いている)。
  let offline = $state(false);
  let retry: ReturnType<typeof autoRetry> | null = null;
  let initial = $state(true);

  // 次のページを裏で先に取っておく置き場。クリックを待たずに用意して
  // おくので「もっと読む」が一瞬で返る。先読みが空なら本当に終わりと
  // 分かるので nextMaxId を畳んでボタンごと消す(Mastodon 系は最後の
  // ページでも max_id を返すため、これが無いと空のボタンが残る)。
  let prefetched = $state<{ items: Status[]; nextMaxId: string | null } | null>(null);

  // 表示フィルター（home/public/tag タブとは別軸）。変えたら頭から読み直す。
  // RT を隠すのは home だけ実効（public/tag はブーストを混ぜない）。
  let onlyMedia = $state(false);
  let hideBoosts = $state(false);
  let hideSensitive = $state(false);

  onMount(() => {
    if (!isLoggedIn()) {
      goto('/');
      return;
    }
    retry = autoRetry(() => load(true));
    void load(true);
    return () => retry?.stop();
  });

  // home のとき、WebTransport で live 新着を受ける。kind が変わると張り直す
  // （home 以外では止める）。届いた status は incoming に溜めるだけ（reveal で出す）。
  $effect(() => {
    if (kind !== 'home' || !isLoggedIn()) return;
    incoming = [];
    const stop = startTimelineStream((s) => {
      const st = s as Status;
      if (!st || !st.id) return;
      if (items.some((it) => it.id === st.id) || incoming.some((it) => it.id === st.id)) return;
      incoming = [st, ...incoming];
    });
    return stop;
  });

  // 溜まった新着を頭へ出す。
  function revealIncoming() {
    items = [...incoming, ...items];
    incoming = [];
    if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  // いまのタブ・フィルターでの 1 ページ取得。load と先読みで共有する。
  function fetchPage(maxId: string | null) {
    return fetchTimeline(kind, {
      tag: kind === 'tag' ? tag : undefined,
      maxId,
      onlyMedia,
      hideBoosts,
      hideSensitive
    });
  }

  async function load(reset: boolean) {
    if (loading) return;
    loading = true;
    error = null;

    if (reset) {
      offline = false;
      items = [];
      nextMaxId = null;
      prefetched = null;
    }

    try {
      const page = await fetchPage(reset ? null : nextMaxId);
      items = reset ? page.items : [...items, ...page.items];
      // 0 件が返ったら、Link が次を匂わせていても終わり扱いにする。
      nextMaxId = page.items.length === 0 ? null : page.nextMaxId;
      if (nextMaxId) void prefetchNext(nextMaxId);
      retry?.ok();
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'unknown';
      if (msg === 'unauthorized') {
        clearToken();
        goto('/');
        return;
      }
      // 本体の読み込みが「繋がらなくて」失敗したときは、エラー文ではなく
      // 静かな待ち表示にして、戻ったら自動で読み直す。それ以外(本当の
      // エラー / もっと読むの失敗)は従来どおり一言だす。
      if (reset && isConnectivityError(e)) {
        offline = true;
        retry?.fail();
      } else {
        error = $t('common.deliverFailedRetry');
      }
    } finally {
      loading = false;
      initial = false;
    }
  }

  // 次のページを裏で取って prefetched に置く。空なら終わりと分かるので
  // nextMaxId を畳む(= ボタンが消える)。cursor が古くなっていたら
  // (リセットや別タブで先へ進んだ)結果は捨てる。
  async function prefetchNext(cursor: string) {
    try {
      const page = await fetchPage(cursor);
      if (cursor !== nextMaxId) return;
      if (page.items.length === 0) {
        nextMaxId = null;
        prefetched = null;
      } else {
        prefetched = { items: page.items, nextMaxId: page.nextMaxId };
      }
    } catch {
      if (cursor === nextMaxId) prefetched = null;
    }
  }

  // 一瞬で湧くと目が追えず落ち着かないので、短い静かな「間」を置いてから
  // 差し込む ── 認知負荷を上げない程度のディレイ。
  const REVEAL_DELAY_MS = 280;
  let revealing = $state(false);
  const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

  // 「もっと読む」。先読みが手元にあれば、行き先を先へ進めて、その次の
  // ページの取得を押した瞬間に非同期で走らせる(reveal は待たせない)。
  // そのうえで静かな間を置いてから手元のぶんを差す。先読みが間に合って
  // いなければ(押すのが早すぎた等)その場で取りに行く従来どおりの保険。
  async function showMore() {
    if (loading || revealing) return;
    if (!prefetched) {
      void load(false);
      return;
    }
    const batch = prefetched;
    prefetched = null;
    nextMaxId = batch.nextMaxId;
    if (nextMaxId) void prefetchNext(nextMaxId);
    revealing = true;
    await sleep(REVEAL_DELAY_MS);
    items = [...items, ...batch.items];
    revealing = false;
  }

  function selectKind(next: TimelineKind) {
    if (next === kind) return;
    kind = next;
    // タグタブはタグ文字列が無いと意味が無いので、まだ何も入って
    // いないときは取りに行かない(入力 → submit でロードされる)。
    if (next === 'tag' && !tag) {
      items = [];
      nextMaxId = null;
      prefetched = null;
      error = null;
      initial = false;
      return;
    }
    void load(true);
  }

  function submitTag() {
    const t = pendingTag.trim().replace(/^#/, '');
    if (!t) return;
    tag = t;
    kind = 'tag';
    void load(true);
  }

  // フィルターを変えたら先頭から読み直す。
  function applyFilters() {
    void load(true);
  }
</script>

{#if composerOpen}
  <Composer
    {replyTo}
    {quoteOf}
    prefillMention={!!replyTo}
    onposted={onPosted}
    oncancel={onCancel}
  />
{/if}

<nav class="tabs timeline" aria-label={$t('timeline.tabsLabel')}>
  <button
    type="button"
    aria-pressed={kind === 'home'}
    onclick={() => selectKind('home')}
  >{$t('timeline.tabHome')}</button>
  <button
    type="button"
    aria-pressed={kind === 'public'}
    onclick={() => selectKind('public')}
  >{$t('timeline.tabPublic')}</button>
  <button
    type="button"
    aria-pressed={kind === 'bubble'}
    onclick={() => selectKind('bubble')}
  >{$t('timeline.tabBubble')}</button>
  <button
    type="button"
    aria-pressed={kind === 'tag'}
    onclick={() => selectKind('tag')}
  >{$t('timeline.tabTag')}</button>
  <TimelineFilter
    bind:onlyMedia
    bind:hideBoosts
    bind:hideSensitive
    showHideBoosts={kind === 'home'}
    onchange={applyFilters}
  />
</nav>

{#if kind === 'tag'}
  <form
    class="timeline form"
    onsubmit={(e) => {
      e.preventDefault();
      submitTag();
    }}
    style="margin-bottom: var(--space-4);"
  >
    <label class="stack-tight">
      <span>{$t('timeline.tagLabel')}</span>
      <input type="text" bind:value={pendingTag} placeholder={$t('timeline.tagPlaceholder')} />
    </label>
  </form>
{/if}

<section class="timeline">
  {#if offline && items.length === 0}
    <p class="loading">{$t('common.reconnecting')}</p>
  {:else if error}
    <p class="error">{error}</p>
  {:else if initial && loading}
    <p class="loading">{$t('common.loading')}</p>
  {:else if items.length === 0 && !loading}
    <p class="prose-small">
      {#if kind === 'home'}
        {$t('timeline.emptyHome')}
      {:else if kind === 'bubble'}
        {$t('timeline.emptyBubble')}
      {:else if kind === 'tag' && !tag}
        {$t('timeline.emptyTagPrompt')}
      {:else if kind === 'tag'}
        {$t('timeline.emptyTag', { tag })}
      {:else}
        {$t('timeline.emptyGeneric')}
      {/if}
    </p>
  {/if}

  {#if kind === 'home' && incoming.length > 0}
    <button type="button" class="btn new-posts px-4 py-2" onclick={revealIncoming}>
      {$t('timeline.newPosts')}（{incoming.length}）
    </button>
  {/if}

  {#each items as s (s.id)}
    <StatusCard status={s} canReply onreply={onReply} onquote={onQuote} ondelete={onDelete} />
  {/each}

  {#if !initial && (loading || revealing)}
    <p class="loading">{$t('common.loading')}</p>
  {/if}

  {#if nextMaxId && !loading && !revealing}
    <button class="load-more" onclick={showMore}>{$t('common.loadMore')}</button>
  {/if}
</section>

<footer class="timeline tl-foot">
  <a href={termsHref}>{$t('signup.termsLink')}</a>
  <span class="sep" aria-hidden="true">·</span>
  <a href={privacyHref}>{$t('signup.privacyLink')}</a>
</footer>

<style>
  /* フィードのいちばん下に、利用規約とプライバシーへの静かな入り口。
     罫線でそっと feed と切って、字は muted・中央に。 */
  .tl-foot {
    margin-top: var(--space-8);
    padding-top: var(--space-4);
    border-top: 1px solid var(--color-border);
    text-align: center;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }
  .tl-foot a {
    color: var(--color-text-muted);
  }
  .tl-foot a:hover {
    color: var(--color-text);
  }
  .tl-foot .sep {
    margin-inline: var(--space-2);
    color: var(--color-border-strong);
  }
</style>
