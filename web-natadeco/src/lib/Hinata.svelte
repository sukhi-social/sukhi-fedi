<script lang="ts">
  import type { Snippet } from 'svelte';
  import { isRevealed } from '$lib/hinataVisibility.svelte';

  // ひなたの一言。絵は既定で見せる。見せる/隠すの切り替えはここでは
  // 持たない ── 選んだ人がどこか(/hello)で切り替えた状態を、ここは
  // ただ映すだけ。
  // inline ── 狭い画面で、固定をやめて流れの中に置くか。全身が入って
  // いる絵だけ。既定の /hinata.png は画面の下端から生えるように下を
  // 切ってあるので、流れの中に置くと途中で切れて見える。
  let {
    children,
    side = 'left',
    big = false,
    scale = 1,
    src = '/hinata.png',
    inline = false
  }: {
    children?: Snippet;
    side?: 'left' | 'right';
    big?: boolean;
    scale?: number;
    src?: string;
    inline?: boolean;
  } = $props();
</script>

<div class="hinata">
  <div class="words">
    {@render children?.()}
  </div>
  <div
    class="portrait-wrap"
    class:right={side === 'right'}
    class:inline
    class:big
    style={scale !== 1 ? `--hinata-scale: ${scale}` : undefined}
  >
    {#if isRevealed()}
      <img class="portrait-img" {src} alt="" />
    {:else}
      <div class="portrait" aria-hidden="true">
        <!-- こころクリニックの猫ロゴを参考に、線一本だけの耳。絵の代わりに
             「誰かが居る」感じを持たせる、見せる前の姿。 -->
        <svg class="ears" viewBox="0 0 48 48" fill="none" aria-hidden="true">
          <path
            d="M12 16 C 12 9, 17 6, 20 12"
            stroke="var(--sun)"
            stroke-width="2"
            stroke-linecap="round"
          />
          <path
            d="M36 16 C 36 9, 31 6, 28 12"
            stroke="var(--sun)"
            stroke-width="2"
            stroke-linecap="round"
          />
        </svg>
      </div>
    {/if}
  </div>
</div>

<style>
  .hinata {
    margin-bottom: 1.4rem;
  }

  .words {
    font-family: var(--font-round);
  }

  .words :global(p) {
    margin: 0 0 0.4rem;
  }

  .words :global(p:last-child) {
    margin-bottom: 0;
  }

  /* 画面の左下に固定 ── ページの中身とは別枠で、スクロールしても
     そこに居る。角に置けるのは、絵のぶんの余白が本当に余っている
     広い画面だけ。 */
  .portrait-wrap {
    position: fixed;
    left: 1rem;
    bottom: 1rem;
    z-index: 15;
  }

  .portrait-wrap.right {
    left: auto;
    right: 1rem;
  }

  .portrait-wrap.big .portrait-img {
    height: calc(18rem * var(--hinata-scale, 1));
  }

  .portrait-wrap.big .portrait {
    width: calc(4rem * var(--hinata-scale, 1));
    height: calc(4rem * var(--hinata-scale, 1));
  }

  /* 隠れているあいだは、あたたかい色の丸に、線一本の耳だけ。 */
  .portrait {
    position: relative;
    width: 3rem;
    height: 3rem;
    border-radius: 50%;
    background: var(--blush);
    border: 1px solid var(--sun);
  }

  .ears {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    overflow: visible;
  }

  .portrait-img {
    display: block;
    height: 13rem;
    width: auto;
  }

  /* 920px より狭いと、右下に固定した絵は必ず本文の上に乗る(幅を
     20px きざみで測って出た境目)。サイドバーが下バーに変わる
     折り返し(680px)とは別のところにあるので、ここは自分の幅を持つ。
     狭いあいだは固定をやめて、言葉の下・本文の上に、流れの中に置く
     ── 誰とも重ならないかわりに、その分だけ下が下がる。 */
  @media (max-width: 919px) {
    .portrait-wrap.inline {
      position: static;
      width: fit-content;
      margin: 0.6rem auto 0;
    }

    /* 幅だけで決めると、縦長の絵が伸びすぎる。縦横どちらにも
       上限を置いて、比率は絵そのものに任せる。 */
    .portrait-wrap.inline.big .portrait-img {
      width: auto;
      height: auto;
      max-width: min(11rem, 45vw);
      max-height: 15rem;
    }
  }
</style>
