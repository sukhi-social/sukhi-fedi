<script lang="ts">
  import { isDefaultAvatar, avatarInitial, avatarColor } from '$lib/avatar';
  import { proxyVariants } from '$lib/proxyImage';

  // class はサイズを決める既存のクラス(avatar / avatar-sm / avatar-lg /
  // nav-avatar / quote-avatar)をそのまま受け取る。頭文字のときも同じ
  // クラスを当てるので、丸・大きさは img と揃う。
  let {
    src,
    name,
    class: klass = 'avatar',
    alt = ''
  }: {
    src: string | null | undefined;
    name: string;
    class?: string;
    alt?: string;
  } = $props();

  let fallback = $derived(isDefaultAvatar(src));
  let initial = $derived(avatarInitial(name));
  let color = $derived(avatarColor(name));
</script>

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

<style>
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
