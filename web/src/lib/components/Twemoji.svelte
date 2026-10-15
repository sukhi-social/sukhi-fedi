<script lang="ts">
  // A single emoji char as a self-hosted Twemoji image, so UI icons and
  // unicode reactions look the same on every platform. Falls back to the raw
  // character when it isn't a recognised emoji (e.g. an odd reaction string),
  // so we never render a broken image. `label` overrides the alt text; it
  // defaults to the emoji itself (good for copy + screen readers).
  import { twemojiUrl } from '#lib/emoji.js';

  let { emoji, label = '' }: { emoji: string; label?: string } = $props();

  let url = $derived(twemojiUrl(emoji));
</script>

{#if url}
  <img class="twemoji" src={url} alt={label || emoji} title={label || undefined} draggable="false" />
{:else}
  {emoji}
{/if}
