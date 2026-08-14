<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<script lang="ts">
  import { onMount } from 'svelte';
  import * as api from '$lib/api';
  import type { Emoji } from '$lib/api';
  import { setCustomEmojisCache } from '$lib/emoji-search';
  import Twemoji from './Twemoji.svelte';
  import { t } from '$lib/i18n';

  let { onpick, onclose }: { onpick: (emoji: string) => void; onclose?: () => void } = $props();

  let query = $state('');
  let customEmojis = $state<Emoji[]>([]);
  let selectedCategory = $state<string>('all');

  const QUICK = [
    '👍', '❤️', '😆', '🎉', '😮',
    '😢', '🤔', '🙏', '🔥', '✨',
    '🌸', '☕', '🍵', '🌱', '🐈',
    '🐾', '💡', '👀', '👏', '🥺',
    '😺', '😴', '🫶', '🍡'
  ];

  onMount(() => {
    api.getCustomEmojis()
      .then((list) => {
        const valid = (list || []).filter((e) => e.visible_in_picker !== false);
        customEmojis = valid;
        setCustomEmojisCache(list || []);
      })
      .catch(() => {});
  });

  function pick(e: string) {
    onpick(e);
    onclose?.();
  }

  let categories = $derived.by(() => {
    const set = new Set<string>();
    for (const e of customEmojis) {
      if (e.category) set.add(e.category);
    }
    return Array.from(set).sort();
  });

  let filteredCustom = $derived.by(() => {
    const q = query.trim().toLowerCase();
    if (q) {
      return customEmojis.filter((e) =>
        e.shortcode.toLowerCase().includes(q) ||
        (e.category && e.category.toLowerCase().includes(q))
      );
    }
    if (selectedCategory === 'all') return customEmojis;
    if (selectedCategory === 'quick') return [];
    return customEmojis.filter((e) => e.category === selectedCategory);
  });

  let showQuick = $derived(
    !query.trim() && (selectedCategory === 'all' || selectedCategory === 'quick')
  );
</script>

<div class="reaction-picker" role="dialog" aria-label={$t('reaction.pick')}>
  <div class="header">
    <input
      type="search"
      class="search-input"
      placeholder="Search emoji..."
      bind:value={query}
    />
    {#if onclose}
      <button type="button" class="close-btn" onclick={onclose} aria-label="Close">✕</button>
    {/if}
  </div>

  {#if categories.length > 0 && !query.trim()}
    <div class="category-tabs" role="tablist">
      <button
        type="button"
        class="cat-chip"
        class:active={selectedCategory === 'all'}
        onclick={() => (selectedCategory = 'all')}
      >
        All
      </button>
      <button
        type="button"
        class="cat-chip"
        class:active={selectedCategory === 'quick'}
        onclick={() => (selectedCategory = 'quick')}
      >
        Quick
      </button>
      {#each categories as cat (cat)}
        <button
          type="button"
          class="cat-chip"
          class:active={selectedCategory === cat}
          onclick={() => (selectedCategory = cat)}
        >
          {cat}
        </button>
      {/each}
    </div>
  {/if}

  <div class="emoji-scroll">
    {#if showQuick}
      <div class="section-title">Standard</div>
      <div class="grid">
        {#each QUICK as e (e)}
          <button
            type="button"
            class="pick"
            onclick={() => pick(e)}
            aria-label={e}
            title={e}
          >
            <Twemoji emoji={e} />
          </button>
        {/each}
      </div>
    {/if}

    {#if filteredCustom.length > 0}
      <div class="section-title">Custom ({filteredCustom.length})</div>
      <div class="grid">
        {#each filteredCustom as e (e.shortcode)}
          <button
            type="button"
            class="pick custom"
            onclick={() => pick(`:${e.shortcode}:`)}
            aria-label={e.shortcode}
            title={`:${e.shortcode}:`}
          >
            <img class="emoji-img" src={e.url} alt={`:${e.shortcode}:`} loading="lazy" />
          </button>
        {/each}
      </div>
    {:else if !showQuick}
      <div class="empty-state">No emojis found</div>
    {/if}
  </div>
</div>

<style>
  .reaction-picker {
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: 0.5rem;
    padding: 0.5rem;
    width: 280px;
    max-width: 90vw;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
  }

  .header {
    display: flex;
    align-items: center;
    gap: 0.25rem;
  }

  .search-input {
    flex: 1;
    padding: 0.25rem 0.5rem;
    font-size: 0.875rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm, 0.25rem);
    background: var(--color-surface);
    color: var(--color-text);
  }

  .close-btn {
    background: transparent;
    border: none;
    cursor: pointer;
    color: var(--color-text-muted);
    padding: 0.25rem;
    font-size: 0.875rem;
  }

  .category-tabs {
    display: flex;
    gap: 0.25rem;
    overflow-x: auto;
    padding-bottom: 0.25rem;
    scrollbar-width: thin;
  }

  .cat-chip {
    flex: none;
    background: var(--fill-soft, rgba(128, 128, 128, 0.1));
    border: 1px solid transparent;
    border-radius: 999px;
    padding: 0.125rem 0.5rem;
    font-size: 0.75rem;
    cursor: pointer;
    color: var(--color-text-muted);
    white-space: nowrap;
  }

  .cat-chip:hover {
    background: var(--fill-hover, rgba(128, 128, 128, 0.2));
  }

  .cat-chip.active {
    background: var(--fill-active, rgba(128, 128, 128, 0.3));
    color: var(--color-text);
    font-weight: 600;
  }

  .emoji-scroll {
    max-height: 220px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
    padding-right: 0.125rem;
  }

  .section-title {
    font-size: 0.75rem;
    color: var(--color-text-muted);
    font-weight: 600;
    margin-top: 0.25rem;
  }

  .grid {
    display: grid;
    grid-template-columns: repeat(6, 1fr);
    gap: 0.125rem;
  }

  .pick {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: none;
    padding: 0.25rem;
    font-size: 1.25rem;
    cursor: pointer;
    border-radius: 0.25rem;
    aspect-ratio: 1;
  }

  .pick:hover {
    background: var(--fill-hover, rgba(128, 128, 128, 0.15));
  }

  .emoji-img {
    width: 1.35rem;
    height: 1.35rem;
    object-fit: contain;
  }

  .empty-state {
    padding: 1rem;
    text-align: center;
    color: var(--color-text-muted);
    font-size: 0.875rem;
  }
</style>
