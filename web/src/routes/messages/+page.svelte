<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { getConversations, type Conversation } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { createPager } from '$lib/pager.svelte';
  import { renderEmojis } from '$lib/emoji';
  import { phrase } from '$lib/phrase';
  import { previewOf } from '$lib/preview';
  import Avatar from '$lib/components/Avatar.svelte';
  import { t, locale, type Locale, type TranslationKey } from '$lib/i18n';

  const pager = createPager<Conversation>((maxId) => getConversations({ maxId }));
  let loading = $state(false);
  let error = $state<string | null>(null);
  let initial = $state(true);

  onMount(() => {
    if (!isLoggedIn()) {
      goto('/');
      return;
    }
    void load(true);
  });

  async function load(reset: boolean) {
    if (loading) return;
    loading = true;
    error = null;
    try {
      await (reset ? pager.reset() : pager.more());
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'unknown';
      if (msg === 'unauthorized') {
        clearToken();
        goto('/');
        return;
      }
      error = $t('common.deliverFailedRetry');
    } finally {
      loading = false;
      initial = false;
    }
  }

  // 最後に喋ったのが自分かどうか。Conversation の accounts は「自分以外の
  // 参加者」なので、書いた人がそこに居なければ自分。自分の acct を別に
  // 引かなくていい。
  function lastWasMine(c: Conversation): boolean {
    const author = c.last_status?.account?.id;
    if (!author) return false;
    return !c.accounts.some((a) => a.id === author);
  }

  function withLabel(c: Conversation): string {
    const names = c.accounts.map((a) => a.display_name || a.username);
    if (names.length === 0) return $t('messages.self');
    return names.join($t('messages.nameSep'));
  }

  // Status.svelte と同じ言い方。会話の行は日付まで要らないので、
  // そのままの粒度で借りる。
  function shortTime(
    iso: string | undefined,
    tr: (key: TranslationKey, params?: Record<string, string | number>) => string,
    loc: Locale
  ): string {
    if (!iso) return '';
    try {
      const d = new Date(iso);
      const diff = (Date.now() - d.getTime()) / 1000;
      if (diff < 60) return tr('status.now');
      if (diff < 3600) return tr('status.minutesAgo', { n: Math.floor(diff / 60) });
      if (diff < 86_400) return tr('status.hoursAgo', { n: Math.floor(diff / 3600) });
      if (diff < 86_400 * 7) return tr('status.daysAgo', { n: Math.floor(diff / 86_400) });
      return d.toLocaleDateString(loc === 'ko' ? 'ko-KR' : 'ja-JP');
    } catch {
      return '';
    }
  }
</script>

<header class="timeline page-head">
  <h1>{$t('messages.title')}</h1>
</header>

<section class="timeline">
  {#if error}
    <p class="error">{error}</p>
  {:else if initial && loading}
    <p class="loading">{$t('common.loading')}</p>
  {:else if pager.items.length === 0 && !loading}
    <p class="prose-small">{$t('messages.empty')}</p>
  {/if}

  <!-- 会話の一覧は、中身を読む場所ではなく「どの会話か思い出す場所」。
       だから一行 ── 相手・ひとこと・いつ。行そのものが入口なので、
       「ひらく」ボタンは要らない。既読はスレッド側が開いた時につける。 -->
  {#each pager.items as c (c.id)}
    <a class="convo" class:unread={c.unread} href={`/messages/${c.id}`}>
      <span class="convo-face">
        {#if c.accounts.length > 0}
          <Avatar
            class="avatar avatar-sm"
            src={c.accounts[0].avatar}
            name={c.accounts[0].display_name || c.accounts[0].username}
          />
        {/if}
      </span>

      <span class="convo-body">
        <span class="convo-top">
          <span class="convo-name"
            >{@html renderEmojis(phrase(withLabel(c)), c.accounts[0]?.emojis)}</span
          >
          <span class="convo-when">{shortTime(c.last_status?.created_at, $t, $locale)}</span>
        </span>
        <!-- 誰が最後に喋ったかを、色ではなく文字で。行の頭に相手の名前が
             出るので、自分の返事まで相手から来たように読めていた。 -->
        <span class="convo-line">
          {#if lastWasMine(c)}<span class="convo-mine">{$t('messages.fromMe')}</span>{/if}{previewOf(
            c.last_status?.content
          )}
        </span>
      </span>

      {#if c.unread}
        <span class="unread-dot" aria-label={$t('messages.unread')}></span>
      {/if}
    </a>
  {/each}

  {#if !initial && (loading || pager.revealing)}
    <p class="loading">{$t('common.loading')}</p>
  {/if}

  {#if pager.hasMore && !loading && !pager.revealing}
    <button class="load-more" onclick={() => load(false)}>{$t('common.loadMore')}</button>
  {/if}
</section>

<style>
  .convo {
    display: flex;
    align-items: flex-start;
    gap: var(--space-3);
    padding: var(--space-3) 0;
    border-top: 1px solid var(--color-border);
    color: inherit;
    text-decoration: none;
  }

  .convo-face {
    flex: none;
  }

  /* 名前もひとことも、はみ出さずに畳む。min-width:0 が無いと flex の子は
     縮まないので、長い一行が行を押し広げてしまう。 */
  .convo-body {
    flex: 1;
    min-width: 0;
    display: grid;
    gap: var(--space-1);
  }

  .convo-top {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: var(--space-3);
  }

  .convo-name {
    font-weight: 700;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .convo-when {
    flex: none;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }

  /* ひとことは一行だけ。会話を思い出すのに、それ以上は要らない。 */
  .convo-line {
    color: var(--color-text-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .convo.unread .convo-line {
    color: var(--color-text);
  }

  /* 「自分:」は印であって中身ではないので、ひとことより一段引く。 */
  .convo-mine {
    color: var(--color-text-muted);
  }

  .unread-dot {
    flex: none;
    align-self: center;
    width: 0.5rem;
    height: 0.5rem;
    border-radius: 50%;
    background: var(--color-build);
  }
</style>
