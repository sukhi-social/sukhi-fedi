<script lang="ts">
  // 会話の中の一通。
  //
  // タイムラインの投稿カードは、ここには重すぎる ── 一通ごとに
  // アバター・名前・ハンドル・時刻・丸ボタン五つ。会話は「誰が・何を」で
  // 足りるし、ブーストも引用も、DM には意味がない。
  //
  // Zulip の平らで読みやすいところに、LINE のまとまりを足すあたり:
  //   ・続けて喋ったぶんは、名前を一度だけ
  //   ・自分のは、左に細い線を引くだけで分ける(吹き出しにしない ──
  //     長い文が入るし、和文は左揃えのほうが読める)
  //   ・時刻は端に、薄く
  import { renderEmojis } from '$lib/emoji';
  import { phrase } from '$lib/phrase';
  import Avatar from './Avatar.svelte';
  import type { Status } from '$lib/api';
  import { stripLeadingMentionHtml } from '$lib/preview';
  import { t, locale, type Locale, type TranslationKey } from '$lib/i18n';

  let {
    status,
    mine = false,
    grouped = false
  }: { status: Status; mine?: boolean; grouped?: boolean } = $props();

  let name = $derived(status.account.display_name || status.account.username);

  function shortTime(
    iso: string,
    tr: (key: TranslationKey, params?: Record<string, string | number>) => string,
    loc: Locale
  ): string {
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

<article class="dm" class:mine class:grouped>
  {#if !grouped}
    <header class="dm-head">
      <Avatar class="avatar avatar-sm" src={status.account.avatar} {name} />
      <span class="dm-name">{@html renderEmojis(phrase(name), status.account.emojis)}</span>
      <a class="dm-when" href={`/@${status.account.acct}/${status.id}`}>
        {shortTime(status.created_at, $t, $locale)}
      </a>
    </header>
  {/if}

  {#if status.spoiler_text}
    <details>
      <summary>{status.spoiler_text}</summary>
      <div class="dm-body">{@html stripLeadingMentionHtml(status.content)}</div>
    </details>
  {:else}
    <div class="dm-body">{@html stripLeadingMentionHtml(status.content)}</div>
  {/if}

  {#if status.media_attachments?.length}
    <ul class="dm-media">
      {#each status.media_attachments as m (m.id)}
        <li>
          {#if m.preview_url || m.url}
            <a href={m.url} target="_blank" rel="noopener noreferrer">
              <img src={m.preview_url || m.url} alt={m.description ?? ''} loading="lazy" />
            </a>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</article>

<style>
  .dm {
    padding: var(--space-2) 0 var(--space-2) var(--space-3);
    /* 自分のぶんだけ、左に細い線。吹き出しにはしない ── 長い文も入るし、
       和文は左揃えのほうが読める。色ではなく形で分けるので、色が見え
       にくい人にも同じように分かる。 */
    border-left: 2px solid transparent;
  }

  .dm.mine {
    border-left-color: var(--color-border-strong);
  }

  /* 続けて喋ったぶんは、名前を出さないので上を詰める。 */
  .dm.grouped {
    padding-top: 0;
  }

  .dm-head {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    margin-bottom: var(--space-1);
  }

  .dm-name {
    font-weight: 700;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .dm-when {
    margin-left: auto;
    flex: none;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
    text-decoration: none;
  }

  .dm-when:hover {
    text-decoration: underline;
  }

  /* 名前を出さない行は、アバターぶん字下げして、続きに見えるように。 */
  .dm-body {
    padding-left: calc(36px + var(--space-2));
    overflow-wrap: anywhere;
  }

  .dm-media {
    list-style: none;
    margin: var(--space-2) 0 0;
    padding-left: calc(36px + var(--space-2));
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
  }

  .dm-media img {
    max-width: 12rem;
    border-radius: var(--radius-sm);
  }
</style>
