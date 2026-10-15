<script lang="ts">
  // ナビの小さなドロップダウン。引き金(trigger)と中身(children)を
  // 受けて、開閉だけを世話する。閉じるきっかけは三つ ── 外をクリック、
  // Escape、そして「遷移したら」。項目はどれもページへ行く(or ログ
  // アウト→トップへ)ので、afterNavigate に乗れば、選んだ瞬間に静かに
  // 閉じる。だから中身の項目それぞれに閉じる処理を書かなくていい。
  //
  // 3.1 の左上メニューと同じ ── ときどき訪ねるものを一所にまとめ、
  // 開くまでは何も主張しない。
  import type { Snippet } from 'svelte';
  import { afterNavigate } from '$app/navigation';

  let {
    open = $bindable(false),
    ariaLabel,
    triggerClass = '',
    trigger,
    children
  }: {
    open?: boolean;
    ariaLabel: string;
    triggerClass?: string;
    trigger: Snippet;
    children: Snippet;
  } = $props();

  let root = $state<HTMLElement | null>(null);

  function onWindowClick(e: MouseEvent) {
    if (open && root && !root.contains(e.target as Node)) open = false;
  }
  function onWindowKey(e: KeyboardEvent) {
    if (open && e.key === 'Escape') open = false;
  }

  afterNavigate(({ shallow, type }) => {
    if (shallow && type === 'goto') return;

    open = false;
  });
</script>

<svelte:window onclick={onWindowClick} onkeydown={onWindowKey}></svelte:window>

<div class="nav-menu" bind:this={root}>
  <button
    type="button"
    class={`nav-link nav-menu-trigger ${triggerClass}`}
    aria-haspopup="menu"
    aria-expanded={open}
    aria-label={ariaLabel}
    onclick={() => open = !open}
  >{@render trigger()}</button>

  {#if open}
    <div class="nav-menu-panel" role="menu">
      {@render children()}
    </div>
  {/if}
</div>

<style>
  .nav-menu {
    position: relative;
    display: inline-flex;
  }

  .nav-menu-panel {
    position: absolute;
    top: calc(100% + var(--space-1));
    right: 0;
    z-index: 40;
    min-width: 11rem;
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: var(--space-1);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius);
  }
</style>
