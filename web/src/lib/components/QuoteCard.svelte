<script lang="ts">
  import type { Status } from '$lib/api';
  import Avatar from './Avatar.svelte';
  import { renderEmojis } from '$lib/emoji';
  import { phrase } from '$lib/phrase';

  // 引用された投稿を、小さなカードで添える。タイムラインでは
  // href を渡してその投稿へ飛べるリンクに、作成中のプレビューでは
  // href なしのただの囲みにする ── 見た目は一箇所、ここに置く。
  let { status, href = null }: { status: Status; href?: string | null } = $props();
</script>

<svelte:element
  this={href ? 'a' : 'div'}
  class="quote-card"
  {href}
  role={href ? undefined : 'group'}
>
  <div class="quote-head">
    <Avatar
      class="quote-avatar"
      src={status.account.avatar}
      name={status.account.display_name || status.account.username}
    />
    <span class="quote-name"
      >{@html renderEmojis(
        phrase(status.account.display_name || status.account.username),
        status.account.emojis
      )}</span
    >
    <span class="quote-acct">@{status.account.acct}</span>
  </div>
  <div class="quote-content">{@html renderEmojis(status.content, status.emojis)}</div>
</svelte:element>

<style>
  .quote-card {
    display: block;
    margin-top: 0.5rem;
    padding: 0.5rem 0.75rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    text-decoration: none;
    color: inherit;
  }
  a.quote-card:hover {
    background: var(--fill-soft);
  }
  .quote-head {
    display: flex;
    align-items: center;
    gap: 0.375rem;
    margin-bottom: 0.25rem;
    font-size: var(--text-sm);
    /* 子(名前・ハンドル)が中身の幅で踏ん張らず、行に収まるよう縮める
       のを許す。長い連合ハンドルがカードを突き破るのを止める。 */
    min-width: 0;
  }
  .quote-name {
    font-weight: 600;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .quote-acct {
    color: var(--color-text-muted);
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  /* 引用は小さな添え物のつもりだったのに、中身が長文記事(Article)だと
     丸ごと出てしまっていた ── ここには Status 本体側の「描画後に測って
     畳む」仕組み(collapsible/COLLAPSE_PX)が無かった。カードはもともと
     href でクリックすれば全文へ飛べるので、JS の実測は要らない ──
     line-clamp で行数を決め打ちして切るだけで足りる。 */
  .quote-content {
    font-size: var(--text-sm);
    display: -webkit-box;
    -webkit-line-clamp: 4;
    line-clamp: 4;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
</style>
