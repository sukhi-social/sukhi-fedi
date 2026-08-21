<script lang="ts">
  import type { Snippet } from 'svelte';

  // どのページも「見出し・（あれば）説明・（あれば）右はしのボタン」の
  // 形は同じなのに、余白の値だけがページごとにばらついていた
  // (1.5rem / 1.25rem / 1rem が同じ役割で混ざっていた)。ここに一本化する。
  //
  // 見出し下の余白は、常にこの .header 自身の margin-bottom だけが持つ。
  // h1 や subtitle に margin を持たせると、両方に余白が付いた板の説明欄
  // のように二重に空いてしまうので、中の要素は margin: 0 に固定する。
  let {
    title,
    subtitle,
    actions
  }: { title: string; subtitle?: string | null; actions?: Snippet } = $props();
</script>

<div class="header">
  <div class="titles">
    <h1 class:tight={!!subtitle}>{title}</h1>
    {#if subtitle}<p class="intro">{subtitle}</p>{/if}
  </div>
  {@render actions?.()}
</div>

<style>
  .header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 1rem;
    margin-bottom: 1.25rem;
  }

  h1 {
    font-size: 1.4rem;
    margin: 0;
  }

  h1.tight {
    margin-bottom: 0.25rem;
  }

  .intro {
    margin: 0;
  }
</style>
