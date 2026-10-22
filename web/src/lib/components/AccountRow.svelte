<script lang="ts">
  import type { Account, Relationship } from '#lib/api.js';
  import FollowButton from './FollowButton.svelte';
  import Avatar from './Avatar.svelte';
  import CircleBadge from './CircleBadge.svelte';
  import { phrase } from '#lib/phrase.js';
  import { renderEmojis } from '#lib/emoji.js';

  let {
    account,
    // 自分自身のときはボタンを出さない、外から null を渡す。
    relationship = null
  }: {
    account: Account;
    relationship?: Relationship | null;
  } = $props();

  let name = $derived(account.display_name || account.username);
</script>

<article class="account-row">
  <a class="account-row-link" href={`/@${account.acct}`}>
    <Avatar class="avatar" src={account.avatar} {name} decorations={account.avatar_decorations} />
    <span class="stack-tight">
      <span class="display-name">{@html renderEmojis(phrase(name), account.emojis)}<CircleBadge accountId={account.id} /></span>
      <span class="muted">@{account.acct}</span>
      <!-- 私的メモがあれば、本名の下にそっと。連合しない、あなただけの呼び名。 -->
      {#if relationship?.note}
        <span class="account-row-note">{relationship.note}</span>
      {/if}
    </span>
  </a>
  {#if relationship}
    <FollowButton accountId={account.id} {relationship} />
  {/if}
</article>

<style>
  /* 私的メモ。本名の下に、ひかえめに。 */
  .account-row-note {
    font-size: var(--text-sm);
    color: var(--color-text-muted);
    opacity: 0.8;
  }
</style>
