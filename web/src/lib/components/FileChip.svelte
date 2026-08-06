<script lang="ts">
  // 画像でない添付の見せ方。floorp-clips.pdf の「ファイル」クリップと同じ
  // 約束: 中身はプレビューしない、ファイルであることと名前・拡張子だけ
  // 見せる。ここだけの部品にしておくと、アップロード経路ごと要らなく
  // なったときに DmMessage 側の一行を戻して、このファイルを消すだけで
  // 済む。
  import type { MediaAttachment } from '$lib/api';

  let { media }: { media: MediaAttachment } = $props();

  let name = $derived(media.filename || 'file');
  let ext = $derived.by(() => {
    const dot = name.lastIndexOf('.');
    return dot > 0 ? name.slice(dot + 1).toUpperCase() : '';
  });
</script>

<a class="file-chip" href={media.url} target="_blank" rel="noopener noreferrer" download={name}>
  <span class="file-chip-ext" aria-hidden="true">{ext || '?'}</span>
  <span class="file-chip-name">{name}</span>
</a>

<style>
  .file-chip {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    color: var(--color-text);
    text-decoration: none;
    max-width: 16rem;
  }

  .file-chip:hover {
    border-color: var(--color-text);
  }

  .file-chip-ext {
    flex: none;
    font-size: var(--text-sm);
    font-weight: 700;
    color: var(--color-text-muted);
  }

  .file-chip-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
