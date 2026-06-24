<script lang="ts">
  import type { PreviewCard } from '$lib/api';

  let { card }: { card: PreviewCard } = $props();

  function hostname(url: string): string {
    try {
      return new URL(url).host;
    } catch {
      return '';
    }
  }

  let host = $derived(card.provider_name || hostname(card.url));
</script>

<a class="preview-card" href={card.url} target="_blank" rel="noopener noreferrer nofollow">
  {#if card.image}
    <img class="preview-image" src={card.image} alt="" loading="lazy" />
  {/if}
  <span class="preview-body">
    {#if host}<span class="preview-host muted">{host}</span>{/if}
    {#if card.title}<span class="preview-title">{card.title}</span>{/if}
    {#if card.description}<span class="preview-desc muted">{card.description}</span>{/if}
  </span>
</a>

<style>
  .preview-card {
    display: flex;
    flex-direction: column;
    margin-top: var(--space-2);
    border: 1px solid var(--color-border, rgba(0, 0, 0, 0.12));
    border-radius: var(--radius, 8px);
    overflow: hidden;
    text-decoration: none;
    color: inherit;
  }
  .preview-image {
    width: 100%;
    max-height: 240px;
    object-fit: cover;
    display: block;
  }
  .preview-body {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
    padding: var(--space-3);
  }
  .preview-host {
    font-size: 0.8em;
  }
  .preview-title {
    font-weight: 600;
  }
  .preview-desc {
    font-size: 0.9em;
    /* 二行で、そっと切る。 */
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
</style>
