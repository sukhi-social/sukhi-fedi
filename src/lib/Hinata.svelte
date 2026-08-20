<script lang="ts">
  import type { Snippet } from 'svelte';

  // ひなたの一言。絵はまだ無い ── 余白として空けてあるだけ。トグルは
  // 出さない(消せる絵が無いのに「見せてもいいですか」は変なので)。
  let { children }: { children?: Snippet } = $props();
</script>

<div class="hinata">
  <div class="portrait-wrap" aria-hidden="true">
    <div class="portrait"></div>
    <!-- こころクリニックの猫ロゴを参考に、線一本だけの耳。絵の代わりに
         「誰かが居る」感じを持たせる試作 ── まだ仮。 -->
    <svg class="ears" viewBox="0 0 48 48" fill="none">
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
  <div class="words">
    {@render children?.()}
  </div>
</div>

<style>
  .hinata {
    display: flex;
    gap: 1rem;
    align-items: flex-start;
    margin-bottom: 1.4rem;
  }

  /* 絵の来る場所。いまは、あたたかい色の丸に、線一本の耳だけ ──
     絵が無くても「居る」感じを持たせたい。用意でき次第、ここに差し込む。 */
  .portrait-wrap {
    position: relative;
    flex: none;
    width: 3rem;
    height: 3rem;
  }

  .portrait {
    width: 100%;
    height: 100%;
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

  .words {
    padding-top: 0.3rem;
    font-family: var(--font-round);
  }

  .words :global(p) {
    margin: 0 0 0.4rem;
  }

  .words :global(p:last-child) {
    margin-bottom: 0;
  }
</style>
