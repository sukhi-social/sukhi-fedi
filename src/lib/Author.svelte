<script lang="ts">
  import type { Author } from '$lib/api';

  // 板の上に立つ、その人。表示名を大きく、ハンドルを小さく ── 同じ
  // 表示名が並んだときに、どちらか分かるように両方出す。
  //
  // compact: 表の列など、狭いところ用。ハンドルと時刻は削って、
  // アバター＋名前だけにする。
  let { author, at, compact = false }: { author: Author; at?: string; compact?: boolean } = $props();
</script>

<span class="who">
  {#if author.avatar_url}
    <img class="avatar" src={author.avatar_url} alt="" width="24" height="24" />
  {:else}
    <span class="avatar blank" aria-hidden="true"></span>
  {/if}
  <span class="name">{author.display_name}</span>
  {#if !compact}
    <span class="muted">@{author.acct}{at ? ` · ${at}` : ''}</span>
  {/if}
</span>

<style>
  .who {
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
    flex-wrap: wrap;
  }

  .avatar {
    width: 24px;
    height: 24px;
    border-radius: 50%;
    object-fit: cover;
    background: var(--sun-soft);
  }

  /* アイコンが無い人の、小さな丸 ── Hinata.svelte の肖像画と同じ色。
     誰であれ、まず暖かい色から始まる。 */
  .blank {
    display: inline-block;
    background: var(--blush);
    border: 1px solid var(--sun);
  }

  .name {
    font-weight: 600;
  }
</style>
