<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<script lang="ts">
  import type { AutocompleteItem } from '$lib/autocomplete.svelte';
  import Avatar from './Avatar.svelte';
  import Twemoji from './Twemoji.svelte';

  let {
    items = [],
    active = 0,
    onpick
  }: {
    items: AutocompleteItem[];
    active: number;
    onpick: (item: AutocompleteItem) => void;
  } = $props();
</script>

<ul class="autocomplete-list" role="listbox" aria-label="Suggestions">
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
            {:else if item.emoji.unicode}
              <Twemoji emoji={item.emoji.unicode} />
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
