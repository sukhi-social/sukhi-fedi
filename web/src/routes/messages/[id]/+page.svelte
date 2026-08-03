<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import {
    getConversationStatuses,
    markConversationRead,
    type Conversation,
    type Status
  } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { reconnect, slowPoll } from '$lib/connection';
  import { createPager } from '$lib/pager.svelte';
  import { renderEmojis } from '$lib/emoji';
  import { phrase } from '$lib/phrase';
  import StatusCard from '$lib/components/Status.svelte';
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
    try {
      if (reset) {
        // 会話そのものを引く口は無いが、既読にする口が会話を返す。開いた
        // ということは読んだということなので、ここで一度で足りる ── 一覧を
        // 丸ごと引いて自分の行を探す必要も、もう無い。
        convo = await markConversationRead(id);
      }
      await (reset ? pager.reset() : pager.more());
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
  function upsert(incoming: Status[]) {
    if (incoming.length === 0) return;
    const byId = new Map(pager.items.map((s) => [s.id, s]));
    for (const s of incoming) byId.set(s.id, s);
    // pager は新しい順。id は snowflake なので、数として降順に。
    pager.items = [...byId.values()].sort((a, b) =>
      a.id.length === b.id.length ? (a.id < b.id ? 1 : -1) : b.id.length - a.id.length
    );
  }

  function onPosted(s: Status) {
    upsert([s]);
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

<header class="timeline page-head">
  <a class="chip" href="/messages">{$t('messages.back')}</a>
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

    {#each messages as s (s.id)}
      <StatusCard status={s} />
    {/each}
  {/if}
</section>

{#if lastStatus && !initial && !error}
  <Composer
    replyTo={lastStatus}
    prefillRecipients={recipients}
    dmConversationId={id}
    onposted={onPosted}
  />
{/if}
