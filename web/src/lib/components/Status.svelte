<script lang="ts">
  import { getAccountCached, type Status } from '$lib/api';
  import Self from './Status.svelte';
  import Avatar from './Avatar.svelte';
  import CircleBadge from './CircleBadge.svelte';
  import StatusActions from './StatusActions.svelte';
  import QuoteCard from './QuoteCard.svelte';
  import StatusMedia from './StatusMedia.svelte';
  import StatusPoll from './StatusPoll.svelte';
  import PreviewCard from './PreviewCard.svelte';
  import Twemoji from './Twemoji.svelte';
  import { renderEmojis } from '$lib/emoji';
  import { renderMfm } from '$lib/mfm';
  import { phrase } from '$lib/phrase';
  import { t, locale, type Locale, type TranslationKey } from '$lib/i18n';

  let {
    status,
    // 返信ボタンを出すか。タイムラインでは true、プロフィール一覧では false
    // など、置き場ごとに切り替えたい。
    canReply = false,
    // リーダーページ（記事ページ）では全文を出したいので、折りたたみを切る。
    full = false,
    onreply,
    onquote,
    onupdate,
    ondelete
  }: {
    status: Status;
    canReply?: boolean;
    full?: boolean;
    onreply?: (s: Status) => void;
    // 引用ボタンが押されたとき。置き場ごとに Composer を引用付きで開く。
    onquote?: (s: Status) => void;
    onupdate?: (s: Status) => void;
    // 自分のノートを削除したとき。置き場ごとに一覧から外したい。
    ondelete?: (s: Status) => void;
  } = $props();

  // Display name falls back to username when servers omit it (Misskey
  // sometimes does for fresh actors).
  let name = $derived(status.account.display_name || status.account.username);
  let avatar = $derived(status.account.avatar || null);
  let ts = $derived(formatTime(status.created_at, $t, $locale));
  // リモートのアカウントは acct に「@ドメイン」が付く。そのときだけ
  // 元の投稿（status.url）への入口を出す。ローカルは詳細ページが本物。
  let isRemote = $derived(status.account.acct.includes('@'));

  // 本文の HTML。Misskey 系のノートは MFM のソース(status.mfm)を持って
  // いる。あればそこから静的なサブセットだけを描く(動きの装飾は落とす)。
  // 無ければサーバが sanitize 済みの content をそのまま。どちらに描くかの
  // 判断は §0 どおりここ一箇所。
  let bodyHtml = $derived(
    status.mfm ? renderMfm(status.mfm, status.emojis) : renderEmojis(status.content, status.emojis)
  );

  // CW（spoiler）を開いているか。閉じている間は本文だけでなく添付も隠す。
  let cwOpen = $state(false);

  // 返信のとき、返信先の人を上に小さく示す。payload には相手の handle が
  // 無いので、in_reply_to_account_id からアカウントだけ遅延 fetch(共有
  // キャッシュ)で引く。取れるまでは名前なしの「返信」だけ静かに出す。
  let replyToAcct = $state<string | null>(null);
  $effect(() => {
    const aid = status.in_reply_to_account_id;
    replyToAcct = null;
    if (!status.in_reply_to_id || !aid) return;
    let alive = true;
    getAccountCached(aid)
      .then((a) => {
        if (alive) replyToAcct = a.acct;
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  });

  // ブーストが続くと元の投稿が埋もれる。長文と同じ「畳んでおいて開く」
  // 作法で、ふだんは一行に畳む。設定ではなく、最初からこの静けさにして
  // おく（畳む/開くの判断は §0 どおりここ一箇所）。クリックでいつもの
  // 入れ子ノートをそのまま開く。
  let boostExpanded = $state(false);
  // 畳んだ行に出す、元の投稿の一行プレビュー。本文 HTML からタグを外して
  // 素のテキストにし、名前と同じ作法（phrase で改行候補→絵文字）で出す。
  let boostPreview = $derived(
    status.reblog ? renderEmojis(phrase(toPlainText(status.reblog.content)), status.reblog.emojis) : ''
  );

  // 長い本文（主に hackers.pub の Article）はタイムラインを埋めないよう
  // 数行で畳み、「続きを読む」で全文を出す。記事だと知らせるフラグは無い
  // ので、描画後の実際の高さで判断する（背が高ければ畳む）。
  const COLLAPSE_PX = 360;
  let contentEl: HTMLDivElement | undefined = $state();
  let collapsible = $state(false);
  let expanded = $state(false);

  $effect(() => {
    // bodyHtml を読むことで、別の投稿に差し替わったら測り直す。
    void bodyHtml;
    // リーダーページでは畳まない。それ以外で背が高ければ畳む。
    collapsible = !full && !!contentEl && contentEl.scrollHeight > COLLAPSE_PX;
  });

  // サーバで sanitize 済みの本文 HTML を、一行プレビュー用の素テキストに
  // する。タグを落として空白を畳むだけ（phrase() がこのあと改行候補と
  // エスケープを足す）。
  function toPlainText(html: string): string {
    return html
      .replace(/<[^>]*>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function formatTime(
    iso: string,
    tr: (key: TranslationKey, params?: Record<string, string | number>) => string,
    loc: Locale
  ): string {
    try {
      const d = new Date(iso);
      const now = Date.now();
      const diff = (now - d.getTime()) / 1000;
      if (diff < 60) return tr('status.now');
      if (diff < 3600) return tr('status.minutesAgo', { n: Math.floor(diff / 60) });
      if (diff < 86_400) return tr('status.hoursAgo', { n: Math.floor(diff / 3600) });
      if (diff < 86_400 * 7) return tr('status.daysAgo', { n: Math.floor(diff / 86_400) });
      return d.toLocaleDateString(loc === 'ko' ? 'ko-KR' : 'ja-JP');
    } catch {
      return iso;
    }
  }
</script>

{#if status.reblog}
  <!-- ブースト: ふだんは一行に畳んでおく（元の投稿が埋もれないように）。
       クリックで「○○がブースト」＋元の status をそのまま開く。返信・
       ブースト等のアクションは入れ子側（本物のノート）に効く。 -->
  {#if boostExpanded}
    <div class="boost">
      <a class="boost-by" href={`/@${status.account.acct}`}>
        <Twemoji emoji="🔁" /> {@html renderEmojis(phrase(name), status.account.emojis)} {$t('status.boostedBy')}
      </a>
      <Self status={status.reblog} {canReply} {onreply} {onquote} {onupdate} {ondelete} />
    </div>
  {:else}
    <button class="boost-compact" onclick={() => (boostExpanded = true)} title={$t('status.expandBoost')}>
      <Avatar class="quote-avatar" src={status.reblog.account.avatar} name={status.reblog.account.display_name || status.reblog.account.username} />
      <span class="boost-compact-by">
        <Twemoji emoji="🔁" /> {@html renderEmojis(phrase(name), status.account.emojis)} {$t('status.boostedBy')}
      </span>
      <span class="boost-compact-preview">{@html boostPreview}</span>
    </button>
  {/if}
{:else}
<article class="status">
  <Avatar class="avatar" src={avatar} {name} />

  <div class="body">
    {#if status.in_reply_to_id}
      {#if replyToAcct}
        <a class="reply-to" href={`/@${replyToAcct}/${status.in_reply_to_id}`}>
          <Twemoji emoji="↩️" /> {$t('status.replyTo', { acct: replyToAcct })}
        </a>
      {:else}
        <span class="reply-to"><Twemoji emoji="↩️" /> {$t('status.replyToUnknown')}</span>
      {/if}
    {/if}

    <header class="meta">
      <a class="display-name" href={`/@${status.account.acct}`}
        >{@html renderEmojis(phrase(name), status.account.emojis)}</a
      >
      <CircleBadge accountId={status.account.id} />
      <a href={`/@${status.account.acct}`}>@{status.account.acct}</a>
      <span>·</span>
      <a class="timestamp" href={`/@${status.account.acct}/${status.id}`} title={status.created_at}>{ts}</a>
      {#if isRemote && status.url}
        <!-- リモートの投稿。元のサーバの本物へ、別タブでそっと開く入口。 -->
        <a
          class="orig"
          href={status.url}
          target="_blank"
          rel="noopener noreferrer"
          title={$t('status.viewOriginal')}
        >
          <Twemoji emoji="↗️" />
        </a>
      {/if}
    </header>

    {#if status.spoiler_text}
      <details bind:open={cwOpen}>
        <summary>{status.spoiler_text}</summary>
        <div class="content">{@html bodyHtml}</div>
      </details>
    {:else}
      <div
        class="content-wrap"
        class:collapsed={collapsible && !expanded}
        class:reader={full}
      >
        <div class="content" bind:this={contentEl}>
          {@html bodyHtml}
        </div>
      </div>
      {#if !full}
        {#if status.title}
          <!-- 記事は専用のリーダーページで読む。短い記事でも入口を出す。 -->
          <a class="read-more" href={`/articles/${status.id}`}>{$t('status.readArticle')}</a>
        {:else if collapsible && !expanded}
          <button class="read-more" onclick={() => (expanded = true)}>{$t('status.readMore')}</button>
        {/if}
      {/if}
    {/if}

    {#if status.quote}
      <QuoteCard
        status={status.quote}
        href={`/@${status.quote.account.acct}/${status.quote.id}`}
      />
    {/if}

    {#if (!status.spoiler_text || cwOpen) && status.media_attachments.length > 0}
      <!-- CW 付きは cwOpen で隠す。CW 無しの sensitive はぼかして「見る」を出す
           （二重に隠さないよう spoiler のときはブラーを掛けない）。 -->
      <StatusMedia
        attachments={status.media_attachments}
        blur={status.sensitive && !status.spoiler_text}
      />
    {/if}

    {#if status.poll}
      <StatusPoll poll={status.poll} />
    {/if}

    <!-- リンクプレビュー。画像や引用があるときは出さない（二重に飾らない）。 -->
    {#if status.card && status.media_attachments.length === 0 && !status.quote}
      <PreviewCard card={status.card} />
    {/if}

    <StatusActions {status} {canReply} {onreply} {onquote} {onupdate} {ondelete} />
  </div>
</article>
{/if}

<style>
  /* 長文（Article）を畳むとき。下端をふわっと薄くして「まだ続く」を示す。 */
  .content-wrap.collapsed {
    max-height: 22rem;
    overflow: hidden;
    -webkit-mask-image: linear-gradient(to bottom, black 70%, transparent);
    mask-image: linear-gradient(to bottom, black 70%, transparent);
  }

  /* リーダー（記事ページ）の本文。畳まず、ゆったり読める行間と段落の間。 */
  .content-wrap.reader :global(.content) {
    line-height: 1.85;
  }
  .content-wrap.reader :global(.content p) {
    margin: 0.85rem 0;
  }
  .content-wrap.reader :global(.content h2:first-child) {
    font-size: 1.4rem;
    margin-top: 0;
  }

  .read-more {
    display: inline-block;
    margin-top: 0.25rem;
    padding: 0.2rem 0.7rem;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
    background: var(--fill-soft);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    text-decoration: none;
    cursor: pointer;
  }
  .read-more:hover {
    color: var(--color-text);
  }

  /* Article の本文には見出し（差し込んだ <h2> や本文中の h2/h3）が来る。
     ブラウザ既定の特大サイズだとタイムラインで浮くので、静かに整える。 */
  .content :global(h2),
  .content :global(h3),
  .content :global(h4) {
    font-size: var(--text-base, 1rem);
    font-weight: 600;
    margin: 0.6rem 0 0.3rem;
    line-height: 1.4;
  }
  .content :global(h2) {
    font-size: 1.1rem;
  }

  /* 静的 MFM の見た目。動きの装飾は描かないので、ここにあるのは静かな
     書式だけ。値はすべてトークンから(§10)。サーバ描画のリモート HTML も
     同じ要素を使うので、両方ここで整う。 */
  .content :global(.mfm-center) {
    text-align: center;
  }
  .content :global(blockquote) {
    margin: var(--space-2) 0;
    padding-left: var(--space-3);
    border-left: 2px solid var(--color-border);
    color: var(--color-text-muted);
  }
  .content :global(code) {
    font-size: 0.95em;
    background: var(--color-bg);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    padding: 0 var(--space-1);
  }
  .content :global(pre) {
    overflow-x: auto;
    background: var(--color-bg);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    padding: var(--space-2) var(--space-3);
  }
  .content :global(pre) :global(code) {
    display: block;
    border: none;
    background: none;
    padding: 0;
  }

  /* 元の投稿への入口。タイムスタンプの隣に、小さく薄く。主張しない。 */
  .orig {
    display: inline-flex;
    align-items: center;
    opacity: 0.55;
    text-decoration: none;
  }
  .orig:hover {
    opacity: 1;
  }

  .boost-by {
    display: block;
    padding: 0.25rem 1rem 0;
    font-size: 0.8rem;
    color: var(--color-text-muted);
    text-decoration: none;
  }

  .boost-by:hover {
    text-decoration: underline;
  }

  /* 畳んだブースト。アバター＋「○○がブースト」＋元の一行を、一行に
     収める。主張せず、でも一行ぶんの気配は残す（quote-acct と同じ作法で
     はみ出しは ellipsis）。 */
  .boost-compact {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    width: 100%;
    padding: 0.4rem 1rem;
    background: none;
    border: none;
    text-align: left;
    font: inherit;
    color: var(--color-text-muted);
    cursor: pointer;
    /* 子（名前・プレビュー）が中身の幅で踏ん張らず行に収まるよう縮める。 */
    min-width: 0;
  }
  .boost-compact:hover {
    background: var(--fill-soft);
  }
  .boost-compact-by {
    flex: none;
    font-size: 0.8rem;
    white-space: nowrap;
  }
  .boost-compact-preview {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    font-size: var(--text-sm);
  }

  /* 「@x への返信」。本文の上に、名前より小さく薄く。主張しすぎず、でも
     これが返信だと分かる程度に。リンクのときだけ hover で下線。 */
  .reply-to {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    margin-bottom: 0.15rem;
    font-size: 0.8rem;
    color: var(--color-text-muted);
    text-decoration: none;
  }
  a.reply-to:hover {
    text-decoration: underline;
  }
</style>
