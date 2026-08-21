<script lang="ts">
  import { t } from '$lib/i18n.svelte';

  // 板の名前の横に添える、小さな印。ボタン類の丸ピル(999px)とは
  // わざと違う形にする ── 「四角の丸い枠」、押せるものではなく
  // 「これは板です」という控えめなラベル。
</script>

<span class="deco-badge">{t().home.title}</span>

<style>
  .deco-badge {
    display: inline-block;
    font-family: var(--font-round);
    font-weight: 700;
    font-size: 0.68rem;
    line-height: 1;
    color: var(--ink-soft);
    border: 1px solid var(--line);
    border-radius: 5px;
    padding: 0.2rem 0.4rem;
    vertical-align: middle;
  }
</style>
