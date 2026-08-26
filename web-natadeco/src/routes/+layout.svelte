<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import '../app.css';
  import { isLoggedIn, signOutServer } from '$lib/auth';
  import { currentTheme, toggleTheme } from '$lib/theme';
  import { t, getLang, toggleLang, langNames } from '$lib/i18n.svelte';
  import BoardNav from '$lib/BoardNav.svelte';

  let { children } = $props();

  // ログイン状態はページ遷移ごとに読み直す ── goto() はレイアウトを
  // 作り直さないので、page.url を読んでおいて遷移のたびに
  // 再チェックする(表示用の一枚だけの、いちばん軽いやりかた)。
  let signedIn = $derived.by(() => {
    page.url;
    return isLoggedIn();
  });

  // 端末の設定のままかもしれないので、実際の色は client 側で読む。
  let theme = $state<'light' | 'dark'>('light');
  onMount(() => {
    theme = currentTheme();

    // PWA としてインストールできるには、push を使うかどうかに関係なく
    // service worker が登録されている必要がある(以前は /settings で
    // 通知を ON にするまで一度も登録されず、インストールバナーが
    // 出なかった)。
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('/service-worker.js').catch(() => {});
    }
  });

  function flipTheme() {
    theme = toggleTheme();
  }

  function flipLang() {
    toggleLang();
  }

  // プロフィール・サインアウトを一つのアイコンの下にまとめる ──
  // Material Design の目安(アイコンボタンが3個を超えたら一つに集約)
  // に沿って、狭い画面でも一行に収まるようにするため。外側クリック・
  // Escape で閉じる。
  let accountMenuOpen = $state(false);
  let accountMenuEl = $state<HTMLDivElement | null>(null);

  function closeAccountMenu() {
    accountMenuOpen = false;
  }

  function onWindowClick(e: MouseEvent) {
    if (accountMenuOpen && accountMenuEl && !accountMenuEl.contains(e.target as Node)) {
      accountMenuOpen = false;
    }
  }

  function onWindowKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') accountMenuOpen = false;
  }

  async function signOut() {
    closeAccountMenu();
    await signOutServer();
    window.location.assign('/');
  }
</script>

<svelte:window onclick={onWindowClick} onkeydown={onWindowKeydown} />

<!-- タブに出る名前も、いま見ている言語で ── 韓国語で開いた人のタブだけ
     日本語のまま、にならないように。辞書から取るので、切り替えた瞬間に
     こちらも一緒に動く。 -->
<svelte:head>
  <title>{t().siteName}</title>
</svelte:head>

<header>
  <div class="measure bar">
    <a class="mark" href="/">{t().siteName}</a>
    <span class="spacer"></span>
    <div class="prefs">
      <button
        class="lang-toggle"
        type="button"
        onclick={flipLang}
        aria-label={t().nav.switchLanguage(langNames[getLang() === 'ja' ? 'ko' : 'ja'])}
      >
        <!-- 地球儀 -->
        <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true">
          <circle cx="9" cy="9" r="7" stroke="currentColor" stroke-width="1.4" />
          <ellipse cx="9" cy="9" rx="3" ry="7" stroke="currentColor" stroke-width="1.4" />
          <path d="M2.2 9h13.6M3 5.5h12M3 12.5h12" stroke="currentColor" stroke-width="1.4" />
        </svg>
      </button>
      <button
        class="theme-toggle"
        type="button"
        onclick={flipTheme}
        aria-label={theme === 'dark' ? t().themeToggle.toLight : t().themeToggle.toDark}
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
    </div>
    <div class="account">
      {#if signedIn}
        <div class="account-menu" bind:this={accountMenuEl}>
          <button
            class="account-toggle"
            type="button"
            aria-haspopup="true"
            aria-expanded={accountMenuOpen}
            aria-label={t().nav.account}
            onclick={() => (accountMenuOpen = !accountMenuOpen)}
          >
            <!-- 人型 -->
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden="true">
              <circle cx="9" cy="6" r="3" fill="currentColor" />
              <path d="M2.5 16c0.9-3.6 4-5.5 6.5-5.5s5.6 1.9 6.5 5.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
            </svg>
          </button>
          {#if accountMenuOpen}
            <div class="account-dropdown" role="menu">
              <a class="dropdown-item" href="/settings" role="menuitem" onclick={closeAccountMenu}
                >{t().nav.profile}</a
              >
              <button class="dropdown-item linklike" type="button" role="menuitem" onclick={signOut}
                >{t().nav.signOut}</button
              >
            </div>
          {/if}
        </div>
      {:else}
        <a class="nav-action" href="/login">{t().nav.signIn}</a>
      {/if}
    </div>
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
    align-items: center;
    flex-wrap: wrap;
    row-gap: 0.5rem;
    gap: 0.9rem;
    padding-top: 0.9rem;
    padding-bottom: 0.9rem;
  }

  /* 言語・テーマは「サイトの見え方」、プロフィール・サインアウトは
     「自分のアカウント」── 別の役目なので、間隔を分けて二つの
     まとまりに見せる(前はピルが一列に並んでいるだけで、どこからが
     何の操作か読み取りにくかった)。 */
  .prefs,
  .account {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  /* 狭い画面では、名前(mark)・言語・テーマの並びと、ログイン状態の
     ボタン群が一行に収まりきらない ── サインイン後は「プロフィール」
     「サインアウト」まで並ぶので、折り返して二行にする。中央寄せに
     切り替えるのは、右にだけ寄って片側が空くのを防ぐため。 */
  @media (max-width: 480px) {
    .bar {
      justify-content: center;
    }

    .spacer {
      display: none;
    }
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

  /* タップ領域は最低 44px 四方(Apple HIG/Material 共通の目安) ──
     min-height + flex中央寄せで、文字の分だけ大きくなる padding 頼みに
     しない(実測で今までのボタン類が軒並み 30px 前後しか無かった)。 */
  .nav-action {
    display: inline-flex;
    align-items: center;
    min-height: 2.75rem;
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

  /* 言語・テーマ・アカウントの三つを、同じ大きさの丸アイコンボタンに
     揃える ── 文字ピルより幅を取らず、一行に収まりやすい
     (Material Design の目安どおり、アイコンボタンが並ぶ形に)。 */
  .lang-toggle,
  .theme-toggle,
  .account-toggle {
    display: grid;
    place-items: center;
    width: 2.75rem;
    height: 2.75rem;
    background: var(--paper-raised);
    border: 1px solid var(--line);
    border-radius: 50%;
    color: var(--ink-soft);
    cursor: pointer;
  }

  .lang-toggle:hover,
  .theme-toggle:hover,
  .account-toggle:hover {
    border-color: var(--sun);
    color: var(--ink);
  }

  .account-menu {
    position: relative;
  }

  .account-dropdown {
    position: absolute;
    top: calc(100% + 0.4rem);
    right: 0;
    z-index: 30;
    display: grid;
    min-width: 9rem;
    background: var(--paper-raised);
    border: 1px solid var(--line);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    padding: 0.4rem;
    gap: 0.2rem;
  }

  .dropdown-item {
    display: flex;
    align-items: center;
    min-height: 2.75rem;
    padding: 0 0.7rem;
    border-radius: calc(var(--radius) * 0.6);
    text-decoration: none;
    color: var(--ink);
    font-size: 0.9rem;
    text-align: left;
    width: 100%;
  }

  .dropdown-item:hover {
    background: var(--sun-soft);
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

  /* main は .measure(幅46rem・margin:0 auto) だけど、その auto は
     サイドバーを除いた残り幅の中で中央寄せするだけ ── ヘッダーの
     .measure は画面全体を基準に中央寄せなので、サイドバーの半分ぶん
     右にずれて、ヘッダーの下の文字と縦の線が揃わなかった。画面幅
     全体を基準に計算し直して、その分だけ左マージンを足す。狭い画面
     ではサイドバー幅ぶんが足りずマイナスになるので、下限は 0 ──
     `.measure` 自身の padding(1.5rem)がすでに既定の余白を持っているので、
     ここでさらに 1.5rem を足すと二重になる(実測で気づいた)。 */
  @media (min-width: 681px) {
    main.measure {
      margin-left: max(0rem, calc((100vw - 46rem) / 2 - var(--sidebar-w)));
      margin-right: auto;
    }
  }

  /* サイドバーが下のバーに変わって場所を空けたぶん、本文が
     隠れないよう底に余白を足す。 */
  @media (max-width: 680px) {
    main {
      padding-bottom: 5rem;
    }
  }
</style>
