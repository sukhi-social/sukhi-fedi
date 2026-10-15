<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<script lang="ts">
  import type { AutocompleteItem } from '#lib/autocomplete.svelte.js';
  import Avatar from './Avatar.svelte';

  let {
    items = [],
    active = 0,
    // DM の入力では候補を入力の上に出す。
    above = false,
    onpick
  }: {
    items: AutocompleteItem[];
    active: number;
    above?: boolean;
    onpick: (item: AutocompleteItem) => void;
  } = $props();
</script>

<ul class="autocomplete-list" class:above role="listbox" aria-label="Suggestions">
  {#each items as item, i (item.type === 'emoji' ? item.emoji.shortcode : item.account.id)}
    <li>
      <button
        type="button"
        role="option"
        aria-selected={i === active}
        class:active={i === active}
        onmousedown={(e) => {
          e.preventDefault();
          onpick(item);
        }}
      >
        {#if item.type === 'emoji'}
          <div class="emoji-preview">
            {#if item.emoji.url}
              <img
                class="custom-emoji-icon"
                src={item.emoji.url}
                alt={item.emoji.shortcode}
                loading="lazy"
              />
            {/if}
          </div>
          <span class="emoji-shortcode">:{item.emoji.shortcode}:</span>
          {#if item.emoji.category}
            <span class="autocomplete-badge">{item.emoji.category}</span>
          {:else if item.emoji.aliases && item.emoji.aliases.length > 0}
            <span class="autocomplete-badge">{item.emoji.aliases[0]}</span>
          {/if}
        {:else if item.type === 'mention'}
          <Avatar
            class="avatar avatar-sm"
            src={item.account.avatar}
            name={item.account.display_name || item.account.username}
          />
          <span class="mention-name">{item.account.display_name || item.account.username}</span>
          <span class="mention-acct">@{item.account.acct}</span>
        {/if}
      </button>
    </li>
  {/each}
</ul>

<style>
  /* 候補の箱。浮かせない ── 入力のすぐ下(DM では上)に、要るあいだだけ場所を取る。
     面の作法にならって枠だけ・影なし(nav-menu と同じ)。 */
  .autocomplete-list {
    list-style: none;
    margin: 0;
    padding: 0;
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
    overflow: hidden;
    max-height: 280px;
    overflow-y: auto;
  }

  /* 打っている途中の候補は、DM では入力の**上**に出す。下は画面の縁で、
     出しても見えない。(親の flex の並びを、この一つだけ入れ替える。) */
  .autocomplete-list.above {
    order: -1;
  }

  .autocomplete-list li + li {
    border-top: 1px solid var(--color-border);
  }

  .autocomplete-list button {
    font: inherit;
    width: 100%;
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-2) var(--space-3);
    background: transparent;
    border: 0;
    text-align: left;
    cursor: pointer;
    color: inherit;
  }

  .autocomplete-list button.active,
  .autocomplete-list button:hover {
    background: var(--color-bg);
  }

  .custom-emoji-icon {
    width: 1.25rem;
    height: 1.25rem;
    object-fit: contain;
    vertical-align: middle;
  }

  .emoji-preview {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 1.5rem;
    height: 1.5rem;
    font-size: 1.1rem;
  }

  .emoji-shortcode {
    font-weight: 600;
    font-family: var(--font-mono, monospace);
    font-size: var(--text-sm);
  }

  .autocomplete-badge {
    margin-left: auto;
    font-size: var(--text-xs);
    color: var(--color-text-muted);
    background: var(--color-bg);
    padding: 0.1rem 0.4rem;
    border-radius: var(--radius-sm);
    border: 1px solid var(--color-border);
  }

  .mention-name {
    font-weight: 700;
  }

  /* ハンドルは縮む側。長い @user@host が名前を押し出さないように。 */
  .mention-acct {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }
</style>
