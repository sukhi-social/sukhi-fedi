<script lang="ts">
  import { langNames, getLang } from '$lib/i18n.svelte';

  // 日本語・韓国語、どちらを主に書くかを切り替えるタブ ── どちらかが
  // 必須でどちらかが「なくてもいい」上乗せ、ではなく対等。データは
  // どちらのタブも常に持ったまま(見えているほうだけ消えたりしない)。
  // 初期表示は、いまのサイトの表示言語に合わせる ── 韓国語で見ている
  // 人には、韓国語のタブが最初から開く。
  let { active = $bindable(getLang()) }: { active?: 'ja' | 'ko' } = $props();
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
    {langNames.ko}
  </button>
</div>

<style>
  .tabs {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 0.6rem;
  }

  /* タップ領域は最低 44px(Apple HIG/Material の目安)。 */
  .tab {
    display: inline-flex;
    align-items: center;
    min-height: 2.75rem;
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
</style>
