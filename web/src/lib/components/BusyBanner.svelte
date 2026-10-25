<script lang="ts">
  // サーバが混んでいて、429 / 503 が返ったとき、素の JSON ではなくこの
  // 一行を出す。置き場は busy.svelte.ts(api.ts の req が一か所で受ける)。
  // 流れの中に置く(UpdateBanner と同じ理由)。秒を数えて、0 になったら
  // 引っ込む ── 待たせる側が居座らない。
  import { busy } from '#lib/busy.svelte.js';
  import { t } from '#lib/i18n.js';

  let now = $state(Date.now());
  const seconds = $derived(Math.max(0, Math.ceil((busy.until - now) / 1000)));
  const show = $derived(busy.until !== 0 && seconds > 0);

  $effect(() => {
    if (busy.until === 0) return;
    now = Date.now();
    const id = setInterval(() => {
      now = Date.now();
    }, 500);
    return () => clearInterval(id);
  });
</script>

{#if show}
  <aside class="busy-banner" role="status" aria-live="polite">
    <p>
      {$t('busy.banner', { seconds })}
      {#if busy.reason}<br /><strong>{busy.reason}</strong>{/if}
    </p>
    <button type="button" class="btn secondary px-3 py-1" onclick={() => window.location.reload()}>
      {$t('busy.retry')}
    </button>
  </aside>
{/if}

<style>
  .busy-banner {
    max-width: 24rem;
    margin-inline: auto;
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius);
    display: flex;
    gap: var(--space-4);
    align-items: center;
    justify-content: space-between;
    font-size: var(--text-sm);
  }

  .busy-banner p {
    margin: 0;
  }
</style>
