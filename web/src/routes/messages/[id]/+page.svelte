<script lang="ts">
  import { onMount, tick, untrack } from 'svelte';
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import {
    currentAccountId,
    getConversationStatuses,
    markConversationRead,
    type Conversation,
    type Status
  } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { reconnect, slowPoll } from '$lib/connection';
  import { createPager } from '$lib/pager.svelte';
  import { atBottom, distanceFromBottom, keepPlaceAfterPrepend, onArrival } from '$lib/scroll';
  import { renderEmojis } from '$lib/emoji';
  import { phrase } from '$lib/phrase';
  import DmMessage from '$lib/components/DmMessage.svelte';
  import Composer from '$lib/components/Composer.svelte';
  import { t } from '$lib/i18n';

  let convo = $state<Conversation | null>(null);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let initial = $state(true);

  let id = $derived($page.params.id ?? '');

  // 会話の中身は新しい順で来る。画面は古いものが上、いつもの会話の並び。
  const pager = createPager<Status>((maxId) => getConversationStatuses(id, { maxId }));
  let messages = $derived([...pager.items].reverse());

  // 自分の発言を見分けるため。取れなくても表示は止めない(印が消えるだけ)。
  let meId = $state<string | null>(null);
  onMount(() => void currentAccountId().then((v) => (meId = v)));

  // 続けて喋ったぶんは、名前を一度だけ。同じ人が、間を置かずに続けたとき
  // だけ畳む ── 一時間空いたら、それは新しいひと続きなので名前を出す。
  const GROUP_WINDOW_MS = 60 * 60 * 1000;

  let rows = $derived(
    messages.map((s, i) => {
      const prev = messages[i - 1];
      const sameAuthor = prev?.account.id === s.account.id;
      const close =
        prev && new Date(s.created_at).getTime() - new Date(prev.created_at).getTime() < GROUP_WINDOW_MS;
      return { status: s, mine: !!meId && s.account.id === meId, grouped: !!(sameAuthor && close) };
    })
  );

  onMount(() => {
    if (!isLoggedIn()) {
      void goto('/');
      return;
    }
    void load(true);
  });

  async function load(reset: boolean) {
    if (loading) return;
    loading = true;
    error = null;

    // 古いぶんは**上に**積まれる。何もしなければ、読んでいた一通が
    // そのぶん下へ流れていく(実測で 4348px ぶん置いていかれた)。
    //
    // ブラウザの位置保持(scroll anchoring)はここでは働かない ── いちばん
    // 上にいるときは効かない仕様で、「もっと読む」は上にあるので、押すには
    // 上にいるしかないから。Safari と iOS にはそもそも無い。だから自分で
    // 覚えて戻す。覚えるのは「下からの距離」── 上に足しても変わらない量。
    const keep = reset ? null : distanceFromBottom(window.scrollY, document.body.scrollHeight);

    try {
      if (reset) {
        // 会話そのものを引く口は無いが、既読にする口が会話を返す。開いた
        // ということは読んだということなので、ここで一度で足りる ── 一覧を
        // 丸ごと引いて自分の行を探す必要も、もう無い。
        convo = await markConversationRead(id);
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
      // 初回が乗ってから拾い直しを始める(空の手元に since_id は無い)。
      armed = true;
      if (reset) void toNewest();
    }
  }

  // 返信は、いまスレッドにいる相手みんなに宛てる。グループのまま返したい
  // ので、最後のメッセージの author 一人だけでなく、会話の参加者全員を
  // 宛先にする(でないと黙って一対一に縮んでしまう)。
  let lastStatus = $derived(messages.length > 0 ? messages[messages.length - 1] : null);
  let recipients = $derived((convo?.accounts ?? []).map((a) => a.acct));

  function withLabel(c: Conversation): string {
    const names = c.accounts.map((a) => a.display_name || a.username);
    if (names.length === 0) return $t('messages.self');
    return names.join($t('messages.nameSep'));
  }

  // ── 同じ一通が三つの道から来る ───────────────────────────────────
  //   自分の送信の返り値 / 拾い直し / (いずれ)live の管
  // **id で、ここ一箇所だけで潰す。** 述語を散らさない。
  function upsert(incoming: Status[], opts: { mine?: boolean } = {}) {
    if (incoming.length === 0) return;

    // **数える前に、居場所を見る。** 差し込んだあとでは中身が伸びていて、
    // 「下にいたかどうか」がもう分からない。
    const wasAtBottom = nowAtBottom();

    const byId = new Map(pager.items.map((s) => [s.id, s]));
    const before = byId.size;
    for (const s of incoming) byId.set(s.id, s);
    const added = byId.size - before;

    // pager は新しい順。id は snowflake なので、数として降順に。
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

  // 会話を開いたら、いちばん新しいところ。返信箱は下に貼りついているので、
  // 直前のやりとりがそのすぐ上に来る ── 開いてすぐ返せる。
  async function toNewest(smooth = false) {
    await tick();
    window.scrollTo({ top: document.body.scrollHeight, behavior: smooth ? 'smooth' : 'auto' });
    unread = false;
  }

  // ── 下にいるときだけ、ついていく ─────────────────────────────────
  //
  // 規則は scroll.ts に一本だけ置いてある。ここはそれをブラウザに繋ぐ側。
  // 遡って読んでいる人は引っぱらない。かわりに「新しいメッセージ」とだけ
  // 置いて、行くかどうかは、その人が決める。
  let unread = $state(false);

  function nowAtBottom(): boolean {
    return atBottom(window.scrollY, window.innerHeight, document.body.scrollHeight);
  }

  onMount(() => {
    const onScroll = () => {
      // 自分で底まで漕いだら、印は役目を終える。
      if (unread && nowAtBottom()) unread = false;
    };
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  });

  function onPosted(s: Status) {
    upsert([s], { mine: true });
  }

  // ── 取りこぼしを拾い直す(最後の砦)───────────────────────────────
  //
  // live の床が無いので、ここが live の代わりを務める。**ストリームは
  // 呼び鈴で、本当のことは API に訊く。** 呼び鈴が鳴らなかった日でも、
  // 扉を開ければ荷物はそこにある。
  //
  // 引き金は三つとも、この一箇所に集める:
  //   ・onMount(開いたとき)── 下の load(true)
  //   ・online 復帰 / タブ復帰 ── reconnect
  //   ・前に出ているあいだ、ゆっくり定期で ── slowPoll
  //
  // 重複は前提。広めに引いて、upsert に任せる。復帰は静かに ──
  // 「再接続しました」は出さない。拾えたものが、ただそこに増える。
  const poll = slowPoll();
  let armed = $state(false);

  async function catchUp() {
    if (!armed || loading) return;
    const newest = pager.items[0]?.id;
    if (!newest) return;
    try {
      const page = await getConversationStatuses(id, { sinceId: newest });
      upsert(page.items);
    } catch {
      // 拾い直しの失敗は黙って飲む。次の引き金でまた来る。
    }
  }

  // **引き金だけを依存にする。** catchUp の中で読む armed / loading /
  // pager.items まで依存に乗ると、upsert が effect を呼び戻して止まらなく
  // なる ── 拾い直しが自分を呼ぶ輪。untrack で切る。
  $effect(() => {
    void $reconnect;
    void $poll;
    untrack(() => void catchUp());
  });
</script>

<!-- 戻る口は屋根の左上へ移した(AppNav)。ここに置くと二つになる。 -->
<header class="timeline page-head">
  {#if convo}
    <h1>{@html renderEmojis(phrase(withLabel(convo)), convo.accounts[0]?.emojis)}</h1>
  {/if}
</header>

<section class="timeline thread">
  {#if error}
    <p class="error">{error}</p>
  {:else if initial && loading}
    <p class="loading">{$t('common.loading')}</p>
  {:else if messages.length === 0}
    <p class="prose-small">{$t('messages.threadEmpty')}</p>
  {:else}
    <!-- 会話は上へ遡るもの。「もっと読む」は上に置く。 -->
    {#if pager.hasMore && !loading && !pager.revealing}
      <button class="load-more" onclick={() => load(false)}>{$t('common.loadMore')}</button>
    {/if}
    {#if !initial && (loading || pager.revealing)}
      <p class="loading">{$t('common.loading')}</p>
    {/if}

    {#each rows as r (r.status.id)}
      <DmMessage status={r.status} mine={r.mine} grouped={r.grouped} />
    {/each}
  {/if}
</section>

<!-- 遡って読んでいるあいだに来たぶん。数は出さない ── 会話の中に居るなら、
     下まで漕げばぜんぶ見える。いくつ、を先に言うのは急かすことになる。
     返信箱のすぐ上に置くので、押す指の行き先が近い。 -->
{#if unread}
  <button class="new-messages" onclick={() => void toNewest(true)}>
    {$t('messages.newMessages')}
  </button>
{/if}

{#if lastStatus && !initial && !error}
  <Composer
    replyTo={lastStatus}
    prefillRecipients={recipients}
    dmConversationId={id}
    onposted={onPosted}
  />
{/if}
