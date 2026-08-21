<script lang="ts">
  import { onMount } from 'svelte';
  import '../app.css';
  import { isLoggedIn, signOutServer } from '$lib/auth';
  import { currentTheme, toggleTheme } from '$lib/theme';
  import BoardNav from '$lib/BoardNav.svelte';

  let { children } = $props();

  // ログイン状態はページ遷移ごとに読み直す ── ここではただの
  // 表示用の一枚なので、複雑な状態管理は要らない。
  let signedIn = $state(isLoggedIn());

  // 端末の設定のままかもしれないので、実際の色は client 側で読む。
  let theme = $state<'light' | 'dark'>('light');
  onMount(() => {
    theme = currentTheme();
  });

  function flipTheme() {
    theme = toggleTheme();
  }

  async function signOut() {
    await signOutServer();
    signedIn = false;
    window.location.assign('/');
  }
</script>

<header>
  <div class="measure bar">
    <a class="mark" href="/">ナタデコ</a>
    <span class="spacer"></span>
    <button
      class="theme-toggle"
      type="button"
      onclick={flipTheme}
      aria-label={theme === 'dark' ? '明るい色にする' : '暗い色にする'}
    >
      {#if theme === 'dark'}
        <!-- 月 -->
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <path
            d="M13.5 9.8A5.6 5.6 0 0 1 6.2 2.5a5.8 5.8 0 1 0 7.3 7.3Z"
            fill="currentColor"
          />
        </svg>
      {:else}
        <!-- 陽だまり -->
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <circle cx="8" cy="8" r="3.4" fill="currentColor" />
          <g stroke="currentColor" stroke-width="1.3" stroke-linecap="round">
            <path d="M8 1.2v1.6M8 13.2v1.6M14.8 8h-1.6M2.8 8H1.2" />
            <path d="M12.7 3.3l-1.1 1.1M4.4 11.6l-1.1 1.1M12.7 12.7l-1.1-1.1M4.4 4.4L3.3 3.3" />
          </g>
        </svg>
      {/if}
    </button>
    {#if signedIn}
      <a class="nav-action ghost" href="/settings">プロフィール</a>
      <button class="linklike nav-action" type="button" onclick={signOut}>出る</button>
    {:else}
      <a class="nav-action" href="/login">入る</a>
    {/if}
  </div>
</header>

<div class="shell">
  <BoardNav />
  <main class="measure">
    {@render children()}
  </main>
</div>

<style>
  header {
    border-bottom: 1px solid var(--line);
    background: var(--sun-soft);
  }

  .bar {
    display: flex;
    align-items: baseline;
    gap: 0.9rem;
    padding-top: 0.9rem;
    padding-bottom: 0.9rem;
  }

  .spacer {
    flex: 1;
  }

  .mark {
    font-family: var(--font-round);
    font-weight: 700;
    font-size: 1.05rem;
    letter-spacing: 0.02em;
    text-decoration: none;
  }

  .linklike {
    background: none;
    border: none;
    padding: 0;
    color: inherit;
    cursor: pointer;
    font: inherit;
  }

  .nav-action {
    font-family: var(--font-round);
    font-weight: 700;
    font-size: 0.85rem;
    text-decoration: none;
    background: var(--paper-raised);
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 0.3rem 0.9rem;
  }

  .nav-action:hover {
    border-color: var(--sun);
  }

  .nav-action.ghost {
    background: transparent;
  }

  .theme-toggle {
    display: grid;
    place-items: center;
    width: 1.9rem;
    height: 1.9rem;
    background: var(--paper-raised);
    border: 1px solid var(--line);
    border-radius: 50%;
    color: var(--ink-soft);
    cursor: pointer;
  }

  .theme-toggle:hover {
    border-color: var(--sun);
    color: var(--ink);
  }

  .shell {
    display: flex;
    align-items: flex-start;
  }

  main {
    flex: 1;
    min-width: 0;
    padding-top: 1.75rem;
    padding-bottom: 3rem;
    min-height: 40vh;
  }

  /* サイドバーが下のバーに変わって場所を空けたぶん、本文が
     隠れないよう底に余白を足す。 */
  @media (max-width: 680px) {
    main {
      padding-bottom: 5rem;
    }
  }
</style>
