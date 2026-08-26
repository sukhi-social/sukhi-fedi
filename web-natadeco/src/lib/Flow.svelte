<script lang="ts">
  import { when, localized, type Post } from '$lib/api';
  import { renderEmojis } from '$lib/emoji';
  import { t } from '$lib/i18n.svelte';
  import Author from '$lib/Author.svelte';
  import Reactions from '$lib/Reactions.svelte';

  // 話す板の流れ。平らに、書かれた順（新しい順）。
  //
  // スレッドを組まない代わりに、返信は親を一段だけ抱える ── IRC の
  // `nick:` が一段しか指さないのと同じ深さで、それで会話は追える。
  // 祖父まで辿ると、画面が入れ子で埋まっていく。
  let { rows = $bindable() }: { rows: Post[] } = $props();

  // 同じ人が続けて書いたら、名前は一度だけ。雑談は連投になるので、
  // 出し続けると名前で画面が埋まる。切れる条件は三つ ──
  // 人が変わる / 間に誰かが挟まる（＝これは自動的に人が変わる）/
  // 5 分あく（14:00 と 14:20 は「戻ってきた」で、別の発言）。
  // それと、親を抱える行はまとめない。まとめると糸が見えなくなる。
  const GROUP_MS = 5 * 60 * 1000;

  function joined(row: Post, prev: Post | undefined): boolean {
    if (!prev) return false;
    if (row.parent) return false;
    if (row.author.acct !== prev.author.acct) return false;
    // 列は新しい順なので、prev のほうが後の時刻。
    return new Date(prev.created_at).getTime() - new Date(row.created_at).getTime() < GROUP_MS;
  }

  // たたまれた行を、この場でひらいたもの。ひらくのは読む人の手。
  let opened = $state<number[]>([]);
  const shown = (row: Post) => !row.folded || opened.includes(row.id);
</script>

<ol class="flow">
  {#each rows as row, i (row.id)}
    {@const cont = joined(row, rows[i - 1])}
    <li class="row" class:cont>
      {#if row.parent}
        <a class="parent" href="/posts/{row.parent.id}">
          <span class="parent-who">{row.parent.author.display_name}</span>
          <span class="parent-text">{row.parent.excerpt}</span>
        </a>
      {/if}

      {#if !cont}
        <p class="who">
          <Author author={row.author} at={when(row.created_at)} />
          {#if row.local_only}<span class="local-badge">{t().visibility.badge}</span>{/if}
        </p>
      {/if}

      {#if row.title}
        <h2 class="title"><a href="/posts/{row.id}">{localized(row.title, row.title_i18n)}</a></h2>
      {/if}

      {#if !shown(row)}
        <p class="folded">
          {t().postDetail.folded}
          <button type="button" class="linklike" onclick={() => (opened = [...opened, row.id])}
            >{t().postDetail.unfold}</button
          >
        </p>
      {:else}
        <div class="body">
          {@html renderEmojis(localized(row.content_html, row.content_html_i18n), row.emojis)}
        </div>

        <div class="foot">
          <Reactions id={row.id} bind:reactions={rows[i].reactions} />
          <a class="muted small" href="/posts/{row.id}">{t().flow.open}</a>
        </div>
      {/if}
    </li>
  {/each}
</ol>

<style>
  .flow {
    list-style: none;
    margin: 0;
    padding: 0;
  }

  .row {
    padding: 0.7rem 0;
    border-top: 1px solid var(--line);
  }

  /* 続きの行は、名前のぶんだけ静かに詰める ── 上の行と一続きに
     見えていてほしいので、区切りの線も引かない。 */
  .cont {
    border-top: none;
    padding-top: 0;
  }

  .who {
    margin: 0 0 0.3rem;
  }

  /* 抱えた親。本文ではないので、小さく、色を落として、一行で切る。
     ここを大きくすると、返事より返事先のほうが目立ってしまう。 */
  .parent {
    display: flex;
    gap: 0.45rem;
    align-items: baseline;
    margin-bottom: 0.35rem;
    padding-left: 0.6rem;
    border-left: 2px solid var(--line);
    color: var(--ink-soft);
    font-size: 0.85rem;
    text-decoration: none;
  }

  .parent:hover .parent-text {
    text-decoration: underline;
  }

  .parent-who {
    font-weight: 600;
    flex: none;
  }

  .parent-text {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .title {
    font-size: 1rem;
    margin: 0 0 0.2rem;
  }

  .title a {
    color: inherit;
  }

  .body :global(p) {
    margin: 0.2rem 0;
  }

  .foot {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    flex-wrap: wrap;
    margin-top: 0.35rem;
  }

  .local-badge {
    font-size: 0.75rem;
    color: var(--ink-soft);
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 0 0.4rem;
  }

  /* たたんだ行は、本文の場所に一行だけ(投稿ページと同じ見た目)。 */
  .folded {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.5rem 0.9rem;
    margin: 0.2rem 0;
    color: var(--ink-soft);
    font-size: 0.9rem;
  }

  .linklike {
    display: inline-flex;
    align-items: center;
    min-height: 2.75rem;
    margin: -0.7rem 0;
    background: none;
    border: none;
    padding: 0;
    color: var(--ink-soft);
    text-decoration: underline;
    text-decoration-color: var(--line);
    cursor: pointer;
    font: inherit;
    font-size: 0.8rem;
  }

  .linklike:hover {
    text-decoration-color: var(--sun);
  }
</style>
