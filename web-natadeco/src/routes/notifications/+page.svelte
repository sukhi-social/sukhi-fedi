<script lang="ts">
  import { goto } from '$app/navigation';
  import { listNotices, setReadMarker, signedIn, when, type Notice } from '$lib/api';
  import { renderEmojis } from '$lib/emoji';
  import { t } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  // 友デコを出すと「返事が来ても気づけない」が目に見える形になるので、
  // 一緒に置いた。数は出さない ── 数字は圧になるし、追う人が増える
  // ほど永遠に残るので。開いた時点で「ここまで読んだ」を置く。
  let notices = $state<Notice[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);

  $effect(() => {
    if (!signedIn()) {
      void goto('/login?next=/notifications');
      return;
    }
    loading = true;
    listNotices()
      .then((n) => {
        notices = n;
        if (n[0]) void setReadMarker(n[0].id);
      })
      .catch(() => (error = t().notices.loadError))
      .finally(() => (loading = false));
  });

  function label(n: Notice): string {
    const who = n.account.display_name;
    switch (n.type) {
      case 'favourite':
        return t().notices.favourite(who);
      case 'reblog':
        return t().notices.reblog(who);
      case 'follow':
      case 'follow_request':
        return t().notices.follow(who);
      case 'mention':
        return t().notices.mention(who);
      default:
        return t().notices.other(who);
    }
  }
</script>

<PageHeader title={t().notices.title} subtitle={t().notices.subtitle} />

{#if loading}
  <p class="muted">{t().common.loading}</p>
{:else if error}
  <p class="error">{error}</p>
{:else if notices.length === 0}
  <p class="muted empty">{t().notices.empty}</p>
{:else}
  <ol class="list">
    {#each notices as n (n.id)}
      <li>
        <p class="head">
          <a href="/people/{n.account.id}">{label(n)}</a>
          <span class="muted small">{when(n.created_at)}</span>
        </p>
        {#if n.status}
          <a class="quoted" href="/posts/{n.status.id}">
            {@html renderEmojis(n.status.content, n.status.emojis)}
          </a>
        {/if}
      </li>
    {/each}
  </ol>
{/if}

<p class="back"><a href="/">{t().common.toDecoList}</a></p>

<style>
  .list {
    list-style: none;
    margin: 0;
    padding: 0;
  }

  .list li {
    padding: 0.7rem 0;
    border-top: 1px solid var(--line);
  }

  .head {
    margin: 0;
    display: flex;
    gap: 0.5rem;
    align-items: baseline;
    flex-wrap: wrap;
  }

  .head a {
    color: inherit;
  }

  /* 何についての知らせか、思い出すぶんだけ。本文の場所ではない。 */
  .quoted {
    display: block;
    margin-top: 0.25rem;
    padding-left: 0.6rem;
    border-left: 2px solid var(--line);
    color: var(--ink-soft);
    font-size: 0.9rem;
    text-decoration: none;
    max-height: 4.5em;
    overflow: hidden;
  }

  .empty {
    margin: 1.5rem 0;
  }

  .back {
    margin-top: 2rem;
  }
</style>
