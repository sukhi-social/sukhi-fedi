<script lang="ts">
  import type { Account, Relationship } from '#lib/api.js';
  import FollowButton from './FollowButton.svelte';
  import Avatar from './Avatar.svelte';
  import { phrase } from '#lib/phrase.js';
  import { renderEmojis } from '#lib/emoji.js';

  // アバター＋名前＋操作ボタンの行。解除・外す・削除など、相手の
  // アカウントに対して一手だけ用意したい一覧（ブロック/ミュート管理、リスト
  // メンバー…）で使い回す。ボタンの文言と押したときの動作だけ外から渡す。
  // relationship を渡すと、外す／削除とは別に「フォロー」ボタンも並ぶ。
  // サークルのメンバーで「フォローは別の操作」だと見せたいときに使う。
  let {
    account,
    actionLabel,
    onaction,
    relationship = null,
    onfollowchange
  }: {
    account: Account;
    actionLabel: string;
    onaction: (a: Account) => void;
    relationship?: Relationship | null;
    onfollowchange?: (r: Relationship) => void;
  } = $props();

  let name = $derived(account.display_name || account.username);
</script>

<article class="account-row">
  <a class="account-row-link" href={`/@${account.acct}`}>
    <Avatar class="avatar" src={account.avatar} {name} decorations={account.avatar_decorations} />
    <span class="stack-tight">
      <span class="display-name">{@html renderEmojis(phrase(name), account.emojis)}</span>
      <span class="muted">@{account.acct}</span>
    </span>
  </a>
  {#if relationship}
    <FollowButton accountId={account.id} {relationship} onchange={onfollowchange} />
  {/if}
  <button type="button" class="chip" onclick={() => onaction(account)}>{actionLabel}</button>
</article>
