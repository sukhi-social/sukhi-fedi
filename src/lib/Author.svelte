<script lang="ts">
  import type { Author } from '$lib/api';

  // 板の上に立つ、その人。表示名を大きく、ハンドルを小さく ── 同じ
  // 表示名が並んだときに、どちらか分かるように両方出す。
  let { author, at }: { author: Author; at?: string } = $props();
</script>

<span class="who">
  {#if author.avatar_url}
    <img class="avatar" src={author.avatar_url} alt="" width="24" height="24" />
  {:else}
    <span class="avatar blank" aria-hidden="true"></span>
  {/if}
  <span class="name">{author.display_name}</span>
  <span class="muted">@{author.acct}{at ? ` · ${at}` : ''}</span>
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

  .blank {
    display: inline-block;
    border: 1px solid var(--line);
  }

  .name {
    font-weight: 600;
  }
</style>
