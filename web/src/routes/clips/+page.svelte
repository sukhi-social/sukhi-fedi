<script lang="ts">
  // Floorp Clips のプロトタイプ。「見つけた URL・テキスト・画像を、あとで
  // 使うためにそばへ置いておく」パレット(仮称 floorp-clips.pdf 参照)。
  //
  // sukhi 版はクリップボード自動履歴とローカルファイルパスを扱わない
  // (個人情報の観点、Floorp 側で実装する部分)。それ以外は「自分宛て DM」
  // を保存先に流用する ── 会話・既読・リアルタイム更新・リアクションが
  // タダ乗りできるので、専用のテーブルや API を新しく作らずに済む。ピンは
  // 既存のリアクション機構を PIN_EMOJI で流用する。
  //
  // 自分宛て会話は `accounts` が空になる(自分以外の参加者がいないため)
  // ── /messages/[id] とほぼ同じ組み立てだが、会話 id を route param では
  // なく検索で見つけ、まだ無ければ最初の一通を送るところから始める。
  import { onMount, tick, untrack } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    currentAccount,
    getConversations,
    getConversationStatuses,
    markConversationRead,
    type Account,
    type Status
  } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { reconnect, slowPoll } from '$lib/connection';
  import { createPager } from '$lib/pager.svelte';
  import { atBottom, distanceFromBottom, keepPlaceAfterPrepend, onArrival } from '$lib/scroll';
  import { watchDirect } from '$lib/direct.svelte';
  import { PIN_EMOJI } from '$lib/reactions';
  import DmMessage from '$lib/components/DmMessage.svelte';
  import Composer from '$lib/components/Composer.svelte';
  import { t } from '$lib/i18n';

  // Clips だけ、画像に限らず何でも添付できる(サーバは元々 MIME で
  // 弾いていない)。ここが「アップロードの経路」の入口 ── ローカルの
  // ファイルパスを覚える方式に差し替えるなら、まずこの一行と Composer
  // への渡し方を見直す。アップロードごと要らなくなったら、ここを消して
  // Composer の accept 既定(image/*)に戻すだけで済む。
  const CLIPS_FILE_ACCEPT = '*/*';

  let id = $state<string | null>(null);
  // 自分宛て会話があるかどうか、まだ探しているあいだ。
  let resolving = $state(true);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let initial = $state(true);

  let me = $state<Account | null>(null);
  onMount(() => void currentAccount().then((a) => (me = a)));

  const pager = createPager<Status>((maxId) => getConversationStatuses(id ?? '', { maxId }));
  let messages = $derived([...pager.items].reverse());

  const GROUP_WINDOW_MS = 60 * 60 * 1000;

  let rows = $derived(
    messages.map((s, i) => {
      const prev = messages[i - 1];
      const sameAuthor = prev?.account.id === s.account.id;
      const close =
        prev && new Date(s.created_at).getTime() - new Date(prev.created_at).getTime() < GROUP_WINDOW_MS;
      return { status: s, mine: !!me && s.account.id === me.id, grouped: !!(sameAuthor && close) };
    })
  );

  function isPinned(s: Status): boolean {
    return (s.reactions ?? []).some((r) => r.name === PIN_EMOJI && r.me);
  }

  let pinnedOnly = $state(false);
  let visibleRows = $derived(pinnedOnly ? rows.filter((r) => isPinned(r.status)) : rows);

  // ── 全文検索 ─────────────────────────────────────────────────────
  //
  // 通常の会話ビュー(pager.items)とは別枠。検索中は結果だけを出す ──
  // ページングとリアルタイム更新のぶんの状態(pager/armed/unread)に
  // 検索を混ぜると、両方の面倒を一つの状態で見ることになって崩れやすい。
  let searchQuery = $state('');
  let searchResults = $state<Status[] | null>(null);
  let searching = $state(false);
  let searchRows = $derived(
    (searchResults ?? []).map((s) => ({ status: s, mine: !!me && s.account.id === me.id, grouped: false }))
  );

  $effect(() => {
    const q = searchQuery.trim();
    const cid = id;
    if (!q || !cid) {
      searchResults = null;
      return;
    }
    // 打ってる途中で叩かない。300ms 手が止まったら検索する。
    const timer = setTimeout(async () => {
      searching = true;
      try {
        const page = await getConversationStatuses(cid, { q });
        searchResults = page.items;
      } catch {
        searchResults = [];
      } finally {
        searching = false;
      }
    }, 300);
    return () => clearTimeout(timer);
  });

  // 自分宛て会話を探す。他の参加者が居ない(accounts が空)会話が、それ。
  async function findSelfConversationId(): Promise<string | null> {
    try {
      const page = await getConversations({ limit: 20 });
      return page.items.find((c) => c.accounts.length === 0)?.id ?? null;
    } catch {
      return null;
    }
  }

  onMount(() => {
    if (!isLoggedIn()) {
      void goto('/');
      return;
    }
    void init();
  });

  async function init() {
    resolving = true;
    id = await findSelfConversationId();
    resolving = false;
    if (id) {
      void load(true);
    } else {
      // まだ一通も無い。Composer だけ出して、最初の一通を待つ。
      initial = false;
    }
  }

  async function load(reset: boolean) {
    if (loading || !id) return;
    loading = true;
    error = null;

    const keep = reset ? null : distanceFromBottom(window.scrollY, document.body.scrollHeight);

    try {
      if (reset) {
        await markConversationRead(id);
      }
      await (reset ? pager.reset() : pager.more());

      if (keep !== null) {
        await tick();
        window.scrollTo({ top: keepPlaceAfterPrepend(keep, document.body.scrollHeight) });
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        void goto('/');
        return;
      }
      error = $t('common.deliverFailedRetry');
    } finally {
      loading = false;
      initial = false;
      armed = true;
      if (reset) void toNewest();
    }
  }

  let lastStatus = $derived(messages.length > 0 ? messages[messages.length - 1] : null);

  function upsert(incoming: Status[], opts: { mine?: boolean } = {}) {
    if (incoming.length === 0) return;

    const wasAtBottom = nowAtBottom();

    const byId = new Map(pager.items.map((s) => [s.id, s]));
    const before = byId.size;
    for (const s of incoming) byId.set(s.id, s);
    const added = byId.size - before;

    pager.items = [...byId.values()].sort((a, b) =>
      a.id.length === b.id.length ? (a.id < b.id ? 1 : -1) : b.id.length - a.id.length
    );

    switch (onArrival({ added, wasAtBottom, mine: opts.mine })) {
      case 'follow':
        void toNewest(true);
        break;
      case 'mark':
        unread = true;
        break;
      case 'nothing':
        break;
    }
  }

  async function toNewest(smooth = false) {
    await tick();
    window.scrollTo({ top: document.body.scrollHeight, behavior: smooth ? 'smooth' : 'auto' });
    unread = false;
  }

  let unread = $state(false);

  function nowAtBottom(): boolean {
    return atBottom(window.scrollY, window.innerHeight, document.body.scrollHeight);
  }

  onMount(() => {
    const onScroll = () => {
      if (unread && nowAtBottom()) unread = false;
    };
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  });

  // 最初の一通のときだけ、送れたあとに会話 id を見つけ直す ── その前は
  // 会話そのものが無いので、探しようがない。
  async function onPosted(s: Status) {
    if (!id) {
      const found = await findSelfConversationId();
      if (found) {
        id = found;
        void load(true);
      }
      return;
    }
    upsert([s], { mine: true });
  }

  const poll = slowPoll();
  let armed = $state(false);

  // since_id だけで拾うと、新しい一通は来ても「もう持ってる一通のピンが
  // 増えた」には気づけない ── リアクションは note を新規発行しないので。
  // 直近ぶんを丸ごと引き直して upsert に渡す(id で潰すので、中身だけ
  // 更新されたものはそのまま置き換わる)。Clips は件数が少ない前提なので、
  // 直近の一巻きぶんで足りる。
  async function catchUp() {
    if (!armed || loading || !id) return;
    try {
      const page = await getConversationStatuses(id, {});
      upsert(page.items);
    } catch {
      // 拾い直しの失敗は黙って飲む。次の引き金でまた来る。
    }
  }

  $effect(() => {
    void $reconnect;
    void $poll;
    untrack(() => void catchUp());
  });

  $effect(() => {
    const cid = id;
    if (!cid) return;
    return watchDirect(cid, () => void catchUp());
  });
</script>

<header class="timeline page-head">
  <h1>{$t('clips.title')}</h1>
  {#if !resolving}
    <span class="page-nav">
      <input
        type="text"
        class="clips-search"
        bind:value={searchQuery}
        placeholder={$t('clips.searchPlaceholder')}
        aria-label={$t('clips.searchPlaceholder')}
        autocapitalize="none"
        autocorrect="off"
        spellcheck="false"
      />
      <button
        type="button"
        class="chip"
        aria-pressed={pinnedOnly}
        onclick={() => (pinnedOnly = !pinnedOnly)}
      >
        {pinnedOnly ? $t('clips.showAll') : $t('clips.pinnedOnly')}
      </button>
    </span>
  {/if}
</header>

<section class="timeline thread">
  {#if error}
    <p class="error">{error}</p>
  {:else if searchQuery.trim()}
    {#if searching && searchResults === null}
      <p class="loading">{$t('common.loading')}</p>
    {:else if (searchResults ?? []).length === 0}
      <p class="prose-small">{$t('clips.noResults')}</p>
    {:else}
      {#each searchRows as r (r.status.id)}
        <DmMessage status={r.status} mine={r.mine} grouped={r.grouped} clipsMode />
      {/each}
    {/if}
  {:else if resolving || (initial && loading)}
    <p class="loading">{$t('common.loading')}</p>
  {:else if messages.length === 0}
    <p class="prose-small">{$t('clips.empty')}</p>
  {:else}
    {#if pager.hasMore && !loading && !pager.revealing}
      <button class="load-more" onclick={() => load(false)}>{$t('common.loadMore')}</button>
    {/if}
    {#if !initial && (loading || pager.revealing)}
      <p class="loading">{$t('common.loading')}</p>
    {/if}

    {#if pinnedOnly && visibleRows.length === 0}
      <p class="prose-small">{$t('clips.noPinned')}</p>
    {/if}

    {#each visibleRows as r (r.status.id)}
      <DmMessage status={r.status} mine={r.mine} grouped={r.grouped} clipsMode />
    {/each}
  {/if}
</section>

{#if unread}
  <button class="new-messages" onclick={() => void toNewest(true)}>
    {$t('messages.newMessages')}
  </button>
{/if}

{#if !resolving && !error && me}
  <Composer
    replyTo={lastStatus}
    prefillRecipients={[me.acct]}
    dmConversationId={id ?? 'clips-new'}
    accept={CLIPS_FILE_ACCEPT}
    onposted={onPosted}
  />
{/if}

<style>
  /* DM の入力欄は position: sticky で下に貼りつくが、sticky は
     「スクロールできるだけの中身がある」ときしか画面の底に見えない。
     Clips は最初 0 件から始まる(=中身が画面より低い)のがふつうの状態
     なので、ここだけ本当に固定する。main.wrap の幅と中央寄せ(margin:
     0 auto と max-width)はそのまま効くよう、left/right だけ足す。 */
  :global(main.wrap .composer.composer-dm) {
    position: fixed;
    left: 0;
    right: 0;
  }

  /* main.wrap は本来どのページも下に大きめの余白を持つ(「もっと読む」
     などが底にぴったり付かないように)。固定した入力欄の下にその余白が
     残ると、意味のない空きスクロールになる ── :has() で「実際に Clips の
     入力欄を子に持つ main.wrap」だけに絞って外す。 */
  :global(main.wrap:has(> .composer.composer-dm)) {
    padding-bottom: 0;
  }

  .clips-search {
    flex: 1 1 auto;
    min-width: 10rem;
  }
</style>
