<script lang="ts">
  import { STEPS } from '#lib/deliveryPace.js';
  import { deliveryToasts } from '#lib/deliveryToasts.svelte.js';
  import { t } from '#lib/i18n.js';
</script>

<!-- 自分の投稿が外へ出ていくようすを、右下に小さく。投稿には混ぜない。
     どこへ、いくつ、は言わない。幕は引かず、後ろの画面は押せる。 -->
{#if deliveryToasts.list.length > 0}
  <div class="toasts" role="status" aria-live="polite">
    {#each deliveryToasts.list as toast (toast.id)}
      <ol class="toast" aria-label={$t('status.delivery.label')}>
        {#each STEPS.slice(0, toast.at + 1) as step, i (step)}
          <li class:current={i === toast.at}>
            {$t(`status.delivery.${step}`)}{#if step === 'sending' && i === toast.at && toast.percent != null}{' '}{toast.percent}%{/if}{#if i === toast.at && toast.delayed}{' '}· {$t('status.delivery.delayed')}{/if}
          </li>
        {/each}
      </ol>
    {/each}
  </div>
{/if}

<style>
  .toasts {
    position: fixed;
    inset-inline-end: var(--space-3);
    inset-block-end: calc(var(--dock-h, 0px) + var(--space-3));
    z-index: var(--layer-overlay);
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    max-width: min(16rem, calc(100vw - 2 * var(--space-3)));
    pointer-events: none;
  }
  .toast {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
    padding: var(--space-2) var(--space-3);
    list-style: none;
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius);
    font-size: 0.8rem;
    color: var(--color-text-muted);
  }
  /* 起きたことを、起きた順に、縦に。新しい一行は、下からそっと浮かんで
     現れる。動きを減らす設定の人には、base.css がほぼ止める。 */
  li {
    opacity: 0.65;
    animation: toast-rise 0.6s ease-out;
  }
  li::before {
    content: '✓ ';
  }
  .current {
    opacity: 1;
    font-weight: 600;
  }
  @keyframes toast-rise {
    from {
      opacity: 0;
      transform: translateY(0.75rem);
    }
  }
</style>
