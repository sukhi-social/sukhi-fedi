<script lang="ts">
  import type { MediaAttachment } from '$lib/api';
  import { browser } from '$app/environment';
  import { proxyVariants } from '$lib/proxyImage';
  import { t } from '$lib/i18n';

  // 動きを控えめにしたい人の合図。base.css の view-transition と同じ
  // prefers-reduced-motion を読んで、gifv の自動ループを止める。true の
  // ときは poster + controls で出して、再生はタップした時だけ。
  const calmMotion =
    browser && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  let {
    attachments,
    // CW 無しの sensitive だけ true。CW 付きは親が cwOpen 側で隠すので、
    // ブラーと二重にはしない。
    blur = false
  }: {
    attachments: MediaAttachment[];
    blur?: boolean;
  } = $props();

  // センシティブ添付のブラーを外したか。クリックで一度だけ表に出す。
  let mediaShown = $state(false);
  // 拡大表示中の画像 URL（null なら閉じている）。
  let lightbox = $state<string | null>(null);
  // ぼかすのは「まだ表に出していない」添付だけ。
  let blurMedia = $derived(blur && !mediaShown);
</script>

<div class="media" class:sensitive={blurMedia}>
  {#if blurMedia}
    <button type="button" class="media-reveal" onclick={() => (mediaShown = true)}>
      {$t('status.tapToShow')}
    </button>
  {/if}
  {#each attachments as m (m.id)}
    {#if m.type === 'image'}
      {@const v = proxyVariants(m.preview_url || m.url)}
      <button
        type="button"
        class="media-zoom"
        onclick={() => (lightbox = m.url)}
        aria-label={m.description || $t('status.imageZoom')}
      >
        <!-- リモート画像はプロキシに avif/webp 変換を頼む。ライトボックスも
             同じ URL を使うので、二枚目の転送は起きない。 -->
        <picture>
          {#if v}
            <source srcset={v.avif} type="image/avif" />
            <source srcset={v.webp} type="image/webp" />
          {/if}
          <img src={m.preview_url || m.url} alt={m.description || ''} loading="lazy" />
        </picture>
      </button>
    {:else if m.type === 'video' || m.type === 'gifv'}
      <!-- gifv は無音ループ動画。ふつうの動画は controls を出す。動きを
           控えめにしたい時は gifv も自動再生せず、poster + controls で
           出して、タップした時だけ動く。 -->
      <video
        src={m.url}
        poster={m.preview_url || undefined}
        controls={m.type === 'video' || calmMotion}
        autoplay={m.type === 'gifv' && !calmMotion}
        loop={m.type === 'gifv'}
        muted={m.type === 'gifv'}
        playsinline
        preload="metadata"
        aria-label={m.description || ''}
      ></video>
    {:else if m.type === 'audio'}
      <audio src={m.url} controls preload="metadata" aria-label={m.description || ''}></audio>
    {:else}
      <!-- 未知の型でも黙って捨てず、せめてリンクで残す。 -->
      <a class="media-fallback" href={m.url} target="_blank" rel="noopener noreferrer">
        {m.description || $t('status.openAttachment')}
      </a>
    {/if}
  {/each}
</div>

{#if lightbox}
  <!-- 画像の拡大。背景全面がボタンなので、どこを押しても/Escで閉じる。 -->
  {@const v = proxyVariants(lightbox)}
  <button
    type="button"
    class="lightbox"
    aria-label={$t('status.close')}
    onclick={() => (lightbox = null)}
    onkeydown={(e) => e.key === 'Escape' && (lightbox = null)}
  >
    <picture>
      {#if v}
        <source srcset={v.avif} type="image/avif" />
        <source srcset={v.webp} type="image/webp" />
      {/if}
      <img src={lightbox} alt="" />
    </picture>
  </button>
{/if}

<style>
  .media video,
  .media audio {
    max-width: 100%;
    border-radius: var(--radius-sm);
  }
  .media-fallback {
    display: inline-block;
    margin-top: 0.25rem;
    font-size: var(--text-sm);
  }

  /* センシティブ添付: 中身をぼかして、上に「見る」ボタンを重ねる。 */
  .media.sensitive {
    position: relative;
    overflow: hidden;
    border-radius: var(--radius-sm);
  }
  .media.sensitive :is(img, video, audio) {
    filter: blur(28px);
    /* ぼかしの縁が透けないよう、わずかに拡大してはみ出させる。 */
    transform: scale(1.06);
    pointer-events: none;
  }
  .media-reveal {
    position: absolute;
    inset: 0;
    z-index: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 100%;
    border: none;
    border-radius: var(--radius-sm);
    background: rgba(0, 0, 0, 0.38);
    color: #fff;
    font: inherit;
    font-size: var(--text-sm);
    cursor: pointer;
  }
  .media-reveal:hover {
    background: rgba(0, 0, 0, 0.48);
  }

  /* サムネイルを包むボタン。クリックでライトボックス。 */
  .media-zoom {
    display: block;
    width: 100%;
    padding: 0;
    border: 0;
    background: none;
    line-height: 0;
    cursor: zoom-in;
  }

  /* 画像の原寸表示。全面の背景ボタン、押すと閉じる。 */
  .lightbox {
    position: fixed;
    inset: 0;
    z-index: 100;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1rem;
    border: 0;
    background: rgba(0, 0, 0, 0.85);
    cursor: zoom-out;
  }
  .lightbox img {
    max-width: 95vw;
    max-height: 95vh;
    object-fit: contain;
    border-radius: var(--radius-sm);
  }
</style>
