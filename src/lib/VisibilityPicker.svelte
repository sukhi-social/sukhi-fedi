<script lang="ts">
  import { t } from '$lib/i18n.svelte';
  import type { Visibility } from '$lib/api';

  // 公開範囲(全域/ローカル)を選ぶタブ。LangTabs と同じ形 ── 見た目を
  // 揃えて、増えたコントロールに見えないように。既定は全域。
  let { active = $bindable<Visibility>('public') }: { active?: Visibility } = $props();
</script>

<div class="tabs" role="tablist">
  <button
    type="button"
    role="tab"
    class="tab"
    class:active={active === 'public'}
    aria-selected={active === 'public'}
    onclick={() => (active = 'public')}
  >
    {t().visibility.public}
  </button>
  <button
    type="button"
    role="tab"
    class="tab"
    class:active={active === 'local'}
    aria-selected={active === 'local'}
    onclick={() => (active = 'local')}
  >
    {t().visibility.local}
  </button>
</div>
<p class="hint muted small">{t().visibility.hint}</p>

<style>
  .tabs {
    display: flex;
    gap: 0.5rem;
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

  .hint {
    margin: 0.35rem 0 0;
  }

  .small {
    font-size: 0.78rem;
  }
</style>
