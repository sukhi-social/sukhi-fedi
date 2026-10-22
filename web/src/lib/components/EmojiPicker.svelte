<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<script lang="ts">
  // カスタム絵文字の一覧。Misskey と同じく、このサーバの絵文字だけを出す。
  //
  // Unicode の絵文字はここに置かない ── 端末のキーボードが持っている仕事で、
  // 二つ持つと「どちらで選ぶか」を人に迷わせるだけになる。ここは、
  // サーバが登録した `:shortcode:` を選ぶための場所。
  //
  // 並びは、サーバのカテゴリ（無ければ「ほか」）ごとの区切り。
  // 最近使ったものは、この端末だけで先頭に出す（emoji-search.ts の履歴）。
  import { onMount } from 'svelte';
  import { getCustomEmojis, type Emoji } from '#lib/api.js';
  import { setCustomEmojisCache, getRecentEmojis, recordRecentEmoji } from '#lib/emoji-search.js';
  import { t } from '#lib/i18n.js';

  let { onpick, onclose }: { onpick: (value: string) => void; onclose?: () => void } = $props();

  const ALL = '__all__';
  const RECENT = '__recent__';
  const UNCATEGORIZED = '__none__';

  let query = $state('');
  let emojis = $state<Emoji[]>([]);
  let loaded = $state(false);
  let failed = $state(false);
  let selected = $state<string>(ALL);
  let recents = $state<string[]>(getRecentEmojis());

  onMount(() => {
    getCustomEmojis()
      .then((list) => {
        const visible = (list ?? []).filter((e) => e.visible_in_picker !== false);
        emojis = visible;
        setCustomEmojisCache(list ?? []);
      })
      .catch(() => (failed = true))
      .finally(() => (loaded = true));
  });

  const catOf = (e: Emoji) => e.category || UNCATEGORIZED;

  // カテゴリの並びは、サーバが届けた順のまま（名前順に直さない）。
  let categories = $derived.by(() => {
    const seen: string[] = [];
    for (const e of emojis) {
      const c = catOf(e);
      if (!seen.includes(c)) seen.push(c);
    }
    return seen;
  });

  const bySortcode = $derived(new Map(emojis.map((e) => [e.shortcode, e])));

  let recentEmojis = $derived(
    recents.map((r) => bySortcode.get(r)).filter((e): e is Emoji => !!e)
  );

  function matches(e: Emoji, q: string): boolean {
    if (e.shortcode.toLowerCase().includes(q)) return true;
    if (e.aliases?.some((a) => a.toLowerCase().includes(q))) return true;
    return !!e.category && e.category.toLowerCase().includes(q);
  }

  // 探すとき。前方一致を先に、残りは後ろに。カテゴリを跨いで一列に並べる。
  let searchResults = $derived.by(() => {
    const q = query.trim().toLowerCase().replace(/^:|:$/g, '');
    if (!q) return null;
    return emojis
      .filter((e) => matches(e, q))
      .sort((a, b) => {
        const ap = a.shortcode.toLowerCase().startsWith(q) ? 0 : 1;
        const bp = b.shortcode.toLowerCase().startsWith(q) ? 0 : 1;
        return ap - bp;
      });
  });

  let visible = $derived.by(() => {
    if (searchResults) return searchResults;
    if (selected === RECENT) return recentEmojis;
    if (selected === ALL) return emojis;
    return emojis.filter((e) => catOf(e) === selected);
  });

  // 探しているときは、タブの区切りではなく一つの列で出す。
  let sections = $derived.by(() => {
    if (searchResults || selected !== ALL) return [{ key: selected, items: visible }];
    return categories.map((c) => ({
      key: c,
      items: emojis.filter((e) => catOf(e) === c)
    }));
  });

  function labelOf(key: string): string {
    if (key === UNCATEGORIZED) return $t('emojiPicker.uncategorized');
    return key;
  }

  function pick(e: Emoji) {
    recordRecentEmoji(e.shortcode);
    recents = getRecentEmojis();
    onpick(`:${e.shortcode}:`);
    onclose?.();
  }

  // 置かれた場所から画面の外へはみ出していたら、内側へ寄せる。
  // 置き場所（ボタンの上・下・左右）は呼ぶ側ごとに違うので、ここでは
  // 「見えている範囲に収まる」ことだけを一か所で引き受ける。
  const MARGIN = 8;
  function keepInViewport(node: HTMLElement) {
    function fit() {
      node.style.translate = '';
      const r = node.getBoundingClientRect();
      const vw = document.documentElement.clientWidth;
      const vh = window.innerHeight;
      let dx = 0;
      let dy = 0;
      if (r.right > vw - MARGIN) dx = vw - MARGIN - r.right;
      if (r.left + dx < MARGIN) dx = MARGIN - r.left;
      if (r.bottom > vh - MARGIN) dy = vh - MARGIN - r.bottom;
      if (r.top + dy < MARGIN) dy = MARGIN - r.top;
      if (dx || dy) node.style.translate = `${dx}px ${dy}px`;
    }
    fit();
    // 読み込みが終わると高さが変わるので、大きさの変化にもついていく。
    const ro = new ResizeObserver(fit);
    ro.observe(node);
    window.addEventListener('resize', fit);
    return () => {
      ro.disconnect();
      window.removeEventListener('resize', fit);
    };
  }

  function onKeydown(ev: KeyboardEvent) {
    if (ev.key === 'Escape') {
      ev.preventDefault();
      onclose?.();
    }
  }
</script>

<svelte:window onkeydown={onKeydown} />

<div class="emoji-picker" role="dialog" {@attach keepInViewport} aria-label={$t('reaction.pick')}>
  <div class="search-row">
    <input
      type="search"
      class="search"
      placeholder={$t('emojiPicker.search')}
      aria-label={$t('emojiPicker.search')}
      bind:value={query}
    />
    {#if onclose}
      <button type="button" class="close" onclick={onclose} aria-label={$t('emojiPicker.close')}>✕</button>
    {/if}
  </div>

  {#if loaded && emojis.length > 0 && !query.trim()}
    <div class="tabs" role="tablist">
      <button
        type="button"
        role="tab"
        class="tab"
        aria-selected={selected === ALL}
        class:active={selected === ALL}
        onclick={() => (selected = ALL)}>{$t('emojiPicker.all')}</button
      >
      {#if recentEmojis.length > 0}
        <button
          type="button"
          role="tab"
          class="tab"
          aria-selected={selected === RECENT}
          class:active={selected === RECENT}
          onclick={() => (selected = RECENT)}>{$t('emojiPicker.recent')}</button
        >
      {/if}
      {#each categories as c (c)}
        <button
          type="button"
          role="tab"
          class="tab"
          aria-selected={selected === c}
          class:active={selected === c}
          onclick={() => (selected = c)}>{labelOf(c)}</button
        >
      {/each}
    </div>
  {/if}

  <div class="body">
    {#if !loaded}
      <p class="empty">{$t('common.loading')}</p>
    {:else if failed || emojis.length === 0}
      <p class="empty">{$t('emojiPicker.none')}</p>
    {:else if searchResults && searchResults.length === 0}
      <p class="empty">{$t('emojiPicker.empty')}</p>
    {:else}
      {#each sections as section (section.key)}
        {#if section.items.length > 0}
          {#if !searchResults && selected === ALL}
            <p class="section-title">{labelOf(section.key)}</p>
          {/if}
          <div class="grid">
            {#each section.items as e (e.shortcode)}
              <button
                type="button"
                class="cell"
                title={`:${e.shortcode}:`}
                aria-label={`:${e.shortcode}:`}
                onclick={() => pick(e)}
              >
                <img src={e.url} alt="" loading="lazy" />
              </button>
            {/each}
          </div>
        {/if}
      {/each}
    {/if}
  </div>
</div>

<style>
  .emoji-picker {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    box-sizing: border-box;
    width: 320px;
    max-width: calc(100vw - 1rem);
    max-height: calc(100dvh - 1rem);
    padding: 0.5rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: 0.5rem;
    box-shadow: var(--shadow-popover);
  }

  .search-row {
    display: flex;
    align-items: center;
    gap: 0.25rem;
  }

  .search {
    flex: 1;
    min-height: 2.5rem;
    padding: 0.25rem 0.6rem;
    font-size: 0.9rem;
    border: 1px solid var(--color-control);
    border-radius: 0.375rem;
    background: var(--color-surface);
    color: var(--color-text);
  }

  .close {
    min-width: 2.5rem;
    min-height: 2.5rem;
    background: transparent;
    border: none;
    border-radius: 0.375rem;
    color: var(--color-text-muted);
    cursor: pointer;
  }

  .close:hover {
    background: var(--fill-hover);
  }

  /* タブは横に流す。数が増えても、一行の高さは変わらない。 */
  .tabs {
    display: flex;
    gap: 0.25rem;
    overflow-x: auto;
    padding-block-end: 0.25rem;
    scrollbar-width: thin;
  }

  .tab {
    flex: none;
    min-height: 2.25rem;
    padding: 0 0.7rem;
    background: var(--fill-soft);
    border: 1px solid transparent;
    border-radius: 999px;
    color: var(--color-text-muted);
    font-size: 0.8rem;
    white-space: nowrap;
    cursor: pointer;
  }

  .tab:hover {
    background: var(--fill-hover);
  }

  .tab.active {
    background: var(--fill-active);
    border-color: var(--fill-active-edge);
    color: var(--color-text);
    font-weight: 600;
  }

  /* 画面が低いときは、枠の高さに合わせて中身だけが縮んでスクロールする。 */
  .body {
    flex: 1 1 auto;
    min-height: 0;
    max-height: 260px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
  }

  .section-title {
    margin: 0.25rem 0 0;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--color-text-muted);
  }

  /* 一つのタップ先は 2.5rem 四方。指で押しても外さない大きさを優先する。 */
  .grid {
    display: grid;
    grid-template-columns: repeat(7, 1fr);
    gap: 0.125rem;
  }

  .cell {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 2.5rem;
    background: transparent;
    border: 1px solid transparent;
    border-radius: 0.375rem;
    cursor: pointer;
  }

  .cell:hover,
  .cell:focus-visible {
    background: var(--fill-hover);
    border-color: var(--fill-active-edge);
    outline: none;
  }

  .cell img {
    width: 1.7rem;
    height: 1.7rem;
    object-fit: contain;
  }

  .empty {
    margin: 0;
    padding: 1rem 0.5rem;
    text-align: center;
    font-size: 0.85rem;
    color: var(--color-text-muted);
  }
</style>
