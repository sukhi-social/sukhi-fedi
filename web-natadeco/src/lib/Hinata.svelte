<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n.svelte';

  // ひなたの一言。絵は既定で見せる。隠したい人だけ、丸を押して隠す
  // ── どちらもトグルで行き来できて、選んだ状態は次からも覚えている
  // (localStorage)。
  let { children }: { children?: Snippet } = $props();

  const HIDDEN_KEY = 'nd.hinataHidden';

  function loadRevealed(): boolean {
    if (typeof localStorage === 'undefined') return true;
    try {
      return localStorage.getItem(HIDDEN_KEY) !== '1';
    } catch {
      return true;
    }
  }

  let revealed = $state(loadRevealed());

  function toggle() {
    revealed = !revealed;
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(HIDDEN_KEY, revealed ? '0' : '1');
    } catch {
      /* 保存できなくても、この場では切り替わる */
    }
  }
</script>

<div class="hinata">
  <div class="words">
    {@render children?.()}
  </div>
  <div class="portrait-wrap">
    {#if revealed}
      <!-- 押せば隠せる(トグル)。 -->
      <button type="button" class="portrait-img-btn" onclick={toggle} aria-label={t().hinata.hide}>
        <img class="portrait-img" src="/hinata.png" alt="" />
      </button>
    {:else}
      <button type="button" class="portrait" onclick={toggle} aria-label={t().hinata.reveal}>
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
      </button>
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
     そこに居る。BoardNav が下バーに変わる画面幅では、その上に
     出るよう底を上げる。 */
  .portrait-wrap {
    position: fixed;
    left: 1rem;
    bottom: 1rem;
    z-index: 15;
  }

  @media (max-width: 680px) {
    .portrait-wrap {
      bottom: 4.5rem;
    }
  }

  /* 押すまでは、あたたかい色の丸に、線一本の耳だけ。 */
  .portrait {
    position: relative;
    width: 3rem;
    height: 3rem;
    padding: 0;
    border-radius: 50%;
    background: var(--blush);
    border: 1px solid var(--sun);
    cursor: pointer;
  }

  .portrait:hover {
    border-color: var(--ink-soft);
  }

  .ears {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    overflow: visible;
  }

  .portrait-img-btn {
    display: block;
    background: none;
    border: none;
    padding: 0;
    cursor: pointer;
  }

  .portrait-img {
    display: block;
    height: 13rem;
    width: auto;
  }
</style>
