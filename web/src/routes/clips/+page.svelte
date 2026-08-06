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
  import DmMessage from '$lib/components/DmMessage.svelte';
  import Composer from '$lib/components/Composer.svelte';
  import { t } from '$lib/i18n';

  // ピンは「自分の Clip に自分で付けた 📌 リアクション」。専用の列を足す
  // 前に、まずこれで足りるかを見たい。
  const PIN_EMOJI = '📌';

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

  async function catchUp() {
    if (!armed || loading || !id) return;
    const newest = pager.items[0]?.id;
    if (!newest) return;
    try {
      const page = await getConversationStatuses(id, { sinceId: newest });
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
      <DmMessage status={r.status} mine={r.mine} grouped={r.grouped} />
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
    onposted={onPosted}
  />
{/if}
