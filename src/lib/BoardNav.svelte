<script lang="ts">
  import { page } from '$app/state';
  import { listDecos, localized, type Deco } from '$lib/api';
  import { t } from '$lib/i18n.svelte';

  // どの板からでも、他の板へすぐ移れるように。Zulip の左の stream 一覧
  // と同じ役目 ── 広い画面ではサイドバー、狭い画面では下のバーに
  // 姿を変える(同じ DOM、CSS だけで切り替える)。
  let decos = $state<Deco[]>([]);

  $effect(() => {
    listDecos()
      .then((d) => (decos = d))
      .catch(() => {});
  });

  const activeSlug = $derived(page.params.slug ?? null);
</script>

<nav class="board-nav" aria-label={t().nav.boardList}>
  <a class="item home" href="/" class:active={!activeSlug}>{t().nav.home}</a>
  {#each decos as deco (deco.id)}
    <a class="item" href="/d/{deco.slug}" class:active={deco.slug === activeSlug}
      >{localized(deco.name, deco.name_i18n)}{t().home.separator}{t().home.title}</a
    >
  {/each}
</nav>

<style>
  .board-nav {
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
    flex: none;
    width: var(--sidebar-w);
    padding: 1.5rem 0.6rem;
    border-right: 1px solid var(--line);
  }

  .item {
    display: block;
    padding: 0.4rem 0.65rem;
    border-radius: var(--radius);
    color: var(--ink-soft);
    text-decoration: none;
    font-size: 0.88rem;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .item:hover {
    background: var(--paper-raised);
  }

  .item.active {
    background: var(--sun-soft);
    color: var(--ink);
    font-weight: 700;
  }

  .home {
    font-family: var(--font-round);
    font-weight: 700;
    color: var(--ink);
    margin-bottom: 0.5rem;
  }

  /* 狭い画面では、左に置く余地が無い。下に固定した横並びのバーに
     姿を変える ── Zulip の stream 一覧の代わりに、指の届くところへ。 */
  @media (max-width: 680px) {
    .board-nav {
      position: fixed;
      left: 0;
      right: 0;
      bottom: 0;
      z-index: 20;
      flex-direction: row;
      width: auto;
      gap: 0.3rem;
      padding: 0.5rem 0.6rem;
      padding-bottom: calc(0.5rem + env(safe-area-inset-bottom));
      border-right: none;
      border-top: 1px solid var(--line);
      background: var(--paper);
      overflow-x: auto;
    }

    .item {
      flex: none;
    }

    .home {
      margin-bottom: 0;
    }
  }
</style>
