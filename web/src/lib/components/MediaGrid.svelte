<script lang="ts">
  import { statusMediaProtected, type Status } from '$lib/api';
  import { proxyVariants } from '$lib/proxyImage';
  import { t } from '$lib/i18n';

  // プロフィールの「写真」表示。メディアを持つ投稿を、サムネの壁にして
  // 一目で見渡せるようにする。タイルは投稿の詳細への入口(タップで一投稿に
  // 戻る作法は崩さない)。CW/センシティブはここで自動では開かず、ぼかした
  // ままにして、開く判断は詳細ページにゆだねる(§statusMediaProtected)。
  let { items }: { items: Status[] } = $props();

  // 各投稿の代表サムネを一枚だけ。先頭の画像/動画を拾う(無ければ捨てる)。
  let tiles = $derived(
    items
      .map((s) => {
        const m = s.media_attachments.find((a) => a.type === 'image' || a.type === 'video' || a.type === 'gifv');
        return m ? { status: s, src: m.preview_url || m.url, alt: m.description || '' } : null;
      })
      .filter((tile): tile is { status: Status; src: string; alt: string } => tile !== null)
  );
</script>

<ul class="media-grid">
  {#each tiles as tile (tile.status.id)}
    {@const v = proxyVariants(tile.src)}
    <li>
      <a
        class="media-grid-tile"
        class:covered={statusMediaProtected(tile.status)}
        href={`/@${tile.status.account.acct}/${tile.status.id}`}
      >
        <picture>
          {#if v}
            <source srcset={v.avif} type="image/avif" />
            <source srcset={v.webp} type="image/webp" />
          {/if}
          <img src={tile.src} alt={tile.alt} loading="lazy" />
        </picture>
        {#if statusMediaProtected(tile.status)}
          <span class="media-grid-cover">{$t('status.tapToShow')}</span>
        {/if}
      </a>
    </li>
  {/each}
</ul>

<style>
  /* トークンのグリッド型(repeat(auto-fill, minmax(...)) + gap)を踏襲。
     値は tokens.css 由来で、ここでは直書きしない。 */
  .media-grid {
    list-style: none;
    margin: 0;
    padding: 0;
    display: grid;
    gap: var(--space-2);
    grid-template-columns: repeat(auto-fill, minmax(10rem, 1fr));
  }
  .media-grid-tile {
    position: relative;
    display: block;
    aspect-ratio: 1 / 1;
    overflow: hidden;
    border-radius: var(--radius-sm);
    border: 1px solid var(--color-border);
  }
  .media-grid-tile img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  /* CW/センシティブのタイルはぼかしたまま。詳細で開く。 */
  .media-grid-tile.covered img {
    filter: blur(28px);
    transform: scale(1.06);
  }
  .media-grid-cover {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.38);
    color: #fff;
    font-size: var(--text-sm);
  }
</style>
