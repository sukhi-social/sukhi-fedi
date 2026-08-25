<script lang="ts">
  import { t } from '$lib/i18n.svelte';
  import type { Visibility } from '$lib/api';

  // 公開範囲(全域/ローカル)を選ぶ欄。書くたびに選び直すものではない
  // (既定の全域のままで書く人がほとんど)ので、タブより控えめな
  // ドロップダウンに ── 常に二つとも見えているタブは、書く欄の余白を
  // 押し出して窮屈にしていた。
  let { active = $bindable<Visibility>('public') }: { active?: Visibility } = $props();
</script>

<label class="picker">
  <span class="muted small">{t().visibility.label}</span>
  <select bind:value={active}>
    <option value="public">{t().visibility.public}</option>
    <option value="local">{t().visibility.local}</option>
  </select>
</label>
<p class="hint muted small">{t().visibility.hint}</p>

<style>
  .picker {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    width: auto;
  }

  /* タップ領域は最低 44px(Apple HIG/Material の目安)。 */
  select {
    width: auto;
    min-height: 2.75rem;
    font-family: var(--font-round);
    font-weight: 700;
    font-size: 0.85rem;
    background: var(--paper);
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 0.3rem 1.7rem 0.3rem 0.9rem;
    color: var(--ink);
    cursor: pointer;
    /* ブラウザ既定の矢印は角ばっていて浮くので、丸に添う自前の矢印を
       背景画像で差す(依存を増やさない)。 */
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' fill='none' stroke='%23888' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 0.7rem center;
  }

  select:focus {
    outline: 3px solid var(--sun-soft);
    outline-offset: 1px;
    border-color: var(--sun);
  }

  .hint {
    margin: 0.35rem 0 0;
  }

  .small {
    font-size: 0.78rem;
  }
</style>
