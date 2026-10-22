<script lang="ts">
  import { isDefaultAvatar, avatarInitial, avatarColor } from '#lib/avatar.js';
  import { proxyVariants } from '#lib/proxyImage.js';
  import type { AvatarDecoration } from '#lib/api.js';

  // class はサイズを決める既存のクラス(avatar / avatar-sm / avatar-lg /
  // nav-avatar / quote-avatar)をそのまま受け取る。頭文字のときも同じ
  // クラスを当てるので、丸・大きさは img と揃う。
  let {
    src,
    name,
    class: klass = 'avatar',
    alt = '',
    decorations = []
  }: {
    src: string | null | undefined;
    name: string;
    class?: string;
    alt?: string;
    decorations?: AvatarDecoration[] | null;
  } = $props();

  let fallback = $derived(isDefaultAvatar(src));
  let initial = $derived(avatarInitial(name));
  let color = $derived(avatarColor(name));
</script>

{#snippet face()}
{#if fallback}
  <!-- 名前のとなりに本名が出ているので、頭文字は飾り扱い(aria-hidden)。 -->
  <span
    class={klass}
    data-avatar-fallback
    style="background: {color.bg}; color: {color.fg};"
    aria-hidden="true">{initial}</span
  >
{:else}
  <!-- リモートアバター(/proxy/avatar/)はプロキシに avif/webp 変換を頼む。
       ローカルや直 URL は v が null になって、素の img のまま。 -->
  {@const v = proxyVariants(src)}
  <picture>
    {#if v}
      <source srcset={v.avif} type="image/avif" />
      <source srcset={v.webp} type="image/webp" />
    {/if}
    <img class={klass} {src} {alt} loading="lazy" />
  </picture>
{/if}
{/snippet}

<!-- Misskey 系の飾り。アイコンの 2 倍の枠をアイコンの中心に重ね、
     角度・反転・ずらしは Misskey の持つ値のまま当てる。pointer-events:none
     なので押す・選ぶの邪魔をしない。飾りの無い人は包まず、これまでと同じ。 -->
{#if decorations && decorations.length > 0}
  <span class="deco-wrap">
    {@render face()}
    {#each decorations as d (d.url)}
      <img
        class="deco"
        src={d.url}
        alt=""
        aria-hidden="true"
        loading="lazy"
        style="transform: rotate({d.angle * 360}deg) scaleX({d.flip_h ? -1 : 1}) translate({d.offset_x * 100}%, {d.offset_y * 100}%);"
      />
    {/each}
  </span>
{:else}
  {@render face()}
{/if}

<style>
  .deco-wrap {
    position: relative;
    display: inline-block;
    flex-shrink: 0;
    /* 投稿のように flex の行に置かれると、既定の stretch で行の高さまで
       伸び、飾りの top: -50% が行の高さ基準になって星が上へずれていた。
       アイコンと同じ高さに留める。 */
    align-self: flex-start;
    line-height: 0;
  }
  .deco {
    position: absolute;
    top: -50%;
    left: -50%;
    width: 200%;
    height: 200%;
    /* base.css の img { max-width: 100% } が 200% を 100% に縮めて、星が
       左上にずれていた。この枠は親の 2 倍が正しいので外す。 */
    max-width: none;
    max-height: none;
    z-index: 1;
    pointer-events: none;
    user-select: none;
  }

  /* 頭文字を中央に。font-size は自分の幅基準(cqw)なので、どのサイズ
     クラスでも比率が揃う ─ サイズごとに値を書かなくていい。 */
  [data-avatar-fallback] {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    container-type: inline-size;
    font-size: 45cqw;
    font-weight: 600;
    line-height: 1;
    text-transform: uppercase;
    user-select: none;
    overflow: hidden;
  }
</style>
