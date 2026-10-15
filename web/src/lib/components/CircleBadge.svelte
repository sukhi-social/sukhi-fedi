<script lang="ts">
  import { onMount } from 'svelte';
  import { circleTitles, ensureCircles } from '#lib/circles.js';

  // 名前の右に出す、サークルの小さな印。accountId がどの exclusive サークルに
  // 入っているかを circleTitles から引いて、入っていれば淡いピルで名前を出す。
  let { accountId }: { accountId: string } = $props();

  onMount(ensureCircles);

  let titles = $derived($circleTitles[accountId] ?? []);
</script>

{#each titles as title (title)}
  <span class="circle-badge" title={title}>{title}</span>
{/each}

<style>
  .circle-badge {
    display: inline-flex;
    align-items: center;
    margin-left: 0.35em;
    padding: 0 0.45em;
    border-radius: 999px;
    background: var(--fill-soft);
    border: 1px solid var(--color-border);
    color: var(--color-text-muted);
    font-size: 0.7rem;
    line-height: 1.6;
    font-weight: 400;
    white-space: nowrap;
    vertical-align: middle;
  }
</style>
