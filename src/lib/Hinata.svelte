<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n.svelte';

  // ひなたの一言。絵は、押すまでは色と耳の線だけ ── 一度見せたら、
  // 次からもそのまま(localStorage)。毎回訊くのは、それはそれで
  // わずらわしいので。
  let { children }: { children?: Snippet } = $props();

  const REVEAL_KEY = 'nd.hinataRevealed';

  function loadRevealed(): boolean {
    if (typeof localStorage === 'undefined') return false;
    try {
      return localStorage.getItem(REVEAL_KEY) === '1';
    } catch {
      return false;
    }
  }

  let revealed = $state(loadRevealed());

  function reveal() {
    revealed = true;
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(REVEAL_KEY, '1');
    } catch {
      /* 保存できなくても、この場では見せる */
    }
  }
</script>

<div class="hinata">
  <div class="portrait-wrap">
    {#if revealed}
      <img class="portrait-img" src="/hinata.png" alt="" />
    {:else}
      <button type="button" class="portrait" onclick={reveal} aria-label={t().hinata.reveal}>
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

  /* 絵の来る場所。押すまでは、あたたかい色の丸に、線一本の耳だけ。 */
  .portrait-wrap {
    position: relative;
    flex: none;
    width: 3rem;
    height: 3rem;
  }

  .portrait {
    width: 100%;
    height: 100%;
    padding: 0;
    border-radius: 50%;
    background: var(--blush);
    border: 1px solid var(--sun);
    cursor: pointer;
  }

  .portrait:hover {
    border-color: var(--ink-soft);
  }

  .portrait-img {
    width: 100%;
    height: 100%;
    border-radius: 50%;
    object-fit: cover;
    object-position: top;
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
