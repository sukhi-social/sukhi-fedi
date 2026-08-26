<script lang="ts">
  import { t } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  // 変えないと決めていることの一枚。ここに書いてあるのは機能の説明では
  // なく約束なので、数も増やさない ── 増えたら、それは約束ではなく
  // 一覧になる。文はぜんぶ辞書(i18n)にあって、ここは並べるだけ。
</script>

<PageHeader title={t().about.title} subtitle={t().about.intro} />

<dl class="promises">
  {#each t().about.promises as p (p.head)}
    <dt>{p.head}</dt>
    <dd>{p.body}</dd>
  {/each}
</dl>

<p class="closing muted">{t().about.closing}</p>

<style>
  .promises {
    margin: 0;
    line-height: 1.7;
  }

  .promises dt {
    font-family: var(--font-round);
    font-weight: 700;
    margin-top: 1.4rem;
  }

  .promises dd {
    margin: 0.25rem 0 0;
  }

  .closing {
    margin-top: 2.4rem;
    line-height: 1.7;
  }
</style>
