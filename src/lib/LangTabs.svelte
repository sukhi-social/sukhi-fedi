<script lang="ts">
  import { langNames } from '$lib/i18n.svelte';
  import { t } from '$lib/i18n.svelte';

  // 主言語(ja、必須)と、上乗せの言語(ko、なくてもいい)を切り替える
  // タブ。データはどちらのタブも常に持ったまま ── 見えているほうだけ
  // 消えるのではなく、両方いつでも書ける。
  let { active = $bindable('ja') }: { active?: 'ja' | 'ko' } = $props();
</script>

<div class="tabs" role="tablist">
  <button
    type="button"
    role="tab"
    class="tab"
    class:active={active === 'ja'}
    aria-selected={active === 'ja'}
    onclick={() => (active = 'ja')}
  >
    {langNames.ja}
  </button>
  <button
    type="button"
    role="tab"
    class="tab"
    class:active={active === 'ko'}
    aria-selected={active === 'ko'}
    onclick={() => (active = 'ko')}
  >
    {langNames.ko}<span class="muted small">({t().common.optional})</span>
  </button>
</div>

<style>
  .tabs {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 0.6rem;
  }

  .tab {
    font-family: var(--font-round);
    font-weight: 700;
    font-size: 0.85rem;
    background: transparent;
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 0.35rem 0.9rem;
    cursor: pointer;
    color: var(--ink-soft);
  }

  .tab.active {
    background: var(--sun-soft);
    border-color: var(--sun);
    color: var(--ink);
  }

  .small {
    font-size: 0.72rem;
    margin-left: 0.3rem;
  }
</style>
