<script lang="ts">
  import type { Status, Reaction } from '$lib/api';
  import * as api from '$lib/api';
  import EmojiPicker from './EmojiPicker.svelte';
  import NavIcon from './NavIcon.svelte';
  import Twemoji from './Twemoji.svelte';
  import { t } from '$lib/i18n';

  let {
    status,
    canReply = false,
    readonly = false,
    onreply,
    onquote,
    onupdate,
    ondelete
  }: {
    status: Status;
    canReply?: boolean;
    // ログインしていない人に見せる読み取り専用の姿。操作の並び(＋⭐🔁返信⋯栞)は
    // 出さず、リアクションは数だけ静かに見せる(押しても何も起きないボタンを
    // 置かない)。
    readonly?: boolean;
    onreply?: (s: Status) => void;
    onquote?: (s: Status) => void;
    onupdate?: (s: Status) => void;
    ondelete?: (s: Status) => void;
  } = $props();

  // ローカル state は楽観更新用。prop が差し替わったら sync する。
  let reactions = $state<Reaction[]>([]);
  let favourited = $state(false);
  let favCount = $state(0);
  let reblogged = $state(false);
  let reblogCount = $state(0);
  let bookmarked = $state(false);
  let pinned = $state(false);
  let pickerOpen = $state(false);
  // 自分のノートか（ピン留め・削除を出すか）。current id は memoise 済みなので
  // 一覧に何枚あっても verify_credentials は一度きり。loggedIn は通報を出すか。
  let mine = $state(false);
  let loggedIn = $state(false);
  let deleting = $state(false);
  // ⋯ メニュー。低頻度・破壊的な操作（ピン留め・通報・削除）をしまっておく。
  let menuOpen = $state(false);
  let reported = $state(false);
  // 🔁 を押すと、ブーストと引用の二択をそっと開く。即ブーストではなく、
  // 一拍おいて選んでもらう（Misskey/Fedibird と同じ作法）。
  let boostMenuOpen = $state(false);

  $effect(() => {
    reactions = status.reactions ?? [];
    favourited = !!status.favourited;
    favCount = status.favourites_count ?? 0;
    reblogged = !!status.reblogged;
    reblogCount = status.reblogs_count ?? 0;
    bookmarked = !!status.bookmarked;
    pinned = !!status.pinned;
  });

  $effect(() => {
    const authorId = status.account.id;
    api.currentAccountId().then((id) => {
      loggedIn = !!id;
      mine = !!id && id === authorId;
    });
  });

  async function toggleReaction(emoji: string) {
    const snapshot = reactions;
    const idx = reactions.findIndex((r) => r.name === emoji);

    if (idx >= 0 && reactions[idx].me) {
      const next = { ...reactions[idx], me: false, count: reactions[idx].count - 1 };
      reactions =
        next.count <= 0
          ? reactions.filter((_, i) => i !== idx)
          : reactions.map((x, i) => (i === idx ? next : x));
      try {
        const s = await api.unreact(status.id, emoji);
        onupdate?.(s);
      } catch {
        reactions = snapshot;
      }
    } else if (idx >= 0) {
      const next = { ...reactions[idx], me: true, count: reactions[idx].count + 1 };
      reactions = reactions.map((x, i) => (i === idx ? next : x));
      try {
        const s = await api.react(status.id, emoji);
        onupdate?.(s);
      } catch {
        reactions = snapshot;
      }
    } else {
      reactions = [...reactions, { name: emoji, count: 1, me: true }];
      try {
        const s = await api.react(status.id, emoji);
        onupdate?.(s);
      } catch {
        reactions = snapshot;
      }
    }
  }

  function pickFromPicker(emoji: string) {
    pickerOpen = false;
    toggleReaction(emoji);
  }

  async function remove() {
    if (deleting) return;
    if (!confirm($t('status.confirmDelete'))) return;
    deleting = true;
    try {
      await api.deleteStatus(status.id);
      // 成功したら一覧から外す（このカードは外れて消える）。
      ondelete?.(status);
    } catch {
      // 失敗したら押せる状態に戻す。federation の Delete は非同期なので
      // ここでの成功はローカル削除＝即ビューから消える、で十分。
      deleting = false;
    }
  }

  async function toggleFavourite() {
    const wasFav = favourited;
    const before = favCount;
    favourited = !wasFav;
    favCount = wasFav ? Math.max(0, before - 1) : before + 1;
    try {
      const s = wasFav ? await api.unfavourite(status.id) : await api.favourite(status.id);
      onupdate?.(s);
    } catch {
      favourited = wasFav;
      favCount = before;
    }
  }

  async function toggleReblog() {
    const was = reblogged;
    const before = reblogCount;
    reblogged = !was;
    reblogCount = was ? Math.max(0, before - 1) : before + 1;
    try {
      const s = was ? await api.unreblog(status.id) : await api.reblog(status.id);
      onupdate?.(s);
    } catch {
      reblogged = was;
      reblogCount = before;
    }
  }

  function boostFromMenu() {
    boostMenuOpen = false;
    void toggleReblog();
  }

  function quoteFromMenu() {
    boostMenuOpen = false;
    onquote?.(status);
  }

  async function toggleBookmark() {
    const was = bookmarked;
    bookmarked = !was;
    try {
      const s = was ? await api.unbookmark(status.id) : await api.bookmark(status.id);
      onupdate?.(s);
    } catch {
      bookmarked = was;
    }
  }

  // 自分のノートをプロフィール先頭に固定する。サーバが ownership を強制する。
  async function togglePin() {
    menuOpen = false;
    const was = pinned;
    pinned = !was;
    try {
      const s = was ? await api.unpinStatus(status.id) : await api.pinStatus(status.id);
      onupdate?.(s);
    } catch {
      pinned = was;
    }
  }

  // 通報。理由は任意（プロンプトをキャンセルしたら何もしない）。送れたら
  // メニューを「通報しました」に変えて二度押しを防ぐ。
  async function doReport() {
    const comment = prompt($t('status.reportPrompt'));
    if (comment === null) return;
    menuOpen = false;
    try {
      await api.reportAccount(status.account.id, {
        statusIds: [status.id],
        comment: comment || undefined
      });
      reported = true;
    } catch {
      // 失敗時は黙って閉じる。開き直せば押し直せる。
    }
  }
</script>

{#if reactions.length > 0}
  <div class="reactions" aria-label={$t('status.reactions')}>
    {#each reactions as r (r.name)}
      <button
        type="button"
        class="reaction-chip"
        class:me={r.me}
        title={r.name}
        disabled={readonly}
        onclick={() => toggleReaction(r.name)}
      >
        {#if r.url}
          <img class="emoji" src={r.url} alt={r.name} loading="lazy" />
        {:else}
          <span class="emoji"><Twemoji emoji={r.name} /></span>
        {/if}
        <span class="count">{r.count}</span>
      </button>
    {/each}
  </div>
{/if}

{#if !readonly}
<footer class="status-actions">
  <button
    type="button"
    class="chip"
    onclick={() => (pickerOpen = !pickerOpen)}
    aria-haspopup="dialog"
    aria-label={$t('reaction.pick')}
  >
    <NavIcon name="plus" />
  </button>
  <button
    type="button"
    class="chip"
    class:active={favourited}
    onclick={toggleFavourite}
    aria-pressed={favourited}
  >
    <NavIcon name="star" filled={favourited} />
    <span class="visually-hidden">{$t('status.favourite')}</span>
    {favCount > 0 ? favCount : ''}
  </button>
  <!-- 🔁 を押すと、ブースト/引用の小メニューがこのボタンの真下に吊るされる
       (相対ラッパ + 絶対配置)。行全体の下ではなくボタン直下に出すことで、
       どのボタンの選択肢かが目で追いやすい。 -->
  <span class="boost-wrap">
    <button
      type="button"
      class="chip"
      class:active={reblogged}
      onclick={() => (boostMenuOpen = !boostMenuOpen)}
      aria-haspopup="menu"
      aria-expanded={boostMenuOpen}
      aria-label={$t('status.boost')}
    >
      <NavIcon name="repeat" />
      {reblogCount > 0 ? reblogCount : ''}
    </button>
    {#if boostMenuOpen}
      <div class="menu boost-menu" role="menu">
        <button
          type="button"
          class="menu-item"
          class:active={reblogged}
          role="menuitem"
          onclick={boostFromMenu}
        >
          <NavIcon name="repeat" />
          <span>{$t('status.boost')}</span>
        </button>
        <button type="button" class="menu-item" role="menuitem" onclick={quoteFromMenu}>
          <NavIcon name="quote" />
          <span>{$t('status.quote')}</span>
        </button>
      </div>
    {/if}
  </span>
  {#if canReply}
    <button type="button" class="chip" onclick={() => onreply?.(status)}>
      {$t('status.reply')}
    </button>
  {/if}
  {#if mine || loggedIn}
    <button
      type="button"
      class="chip"
      onclick={() => (menuOpen = !menuOpen)}
      aria-haspopup="menu"
      aria-expanded={menuOpen}
      aria-label={$t('status.more')}
    >
      <NavIcon name="more" />
    </button>
  {/if}
  <!-- ブックマークは自分だけの栞なので、社交の並び(⭐🔁返信)から
       離して、行の右端にひとり分置く。 -->
  <button
    type="button"
    class="chip bookmark"
    class:active={bookmarked}
    onclick={toggleBookmark}
    aria-pressed={bookmarked}
    aria-label={bookmarked ? $t('status.bookmarkRemove') : $t('status.bookmarkAdd')}
  >
    <NavIcon name="bookmark" filled={bookmarked} />
  </button>
</footer>
{/if}

{#if pickerOpen}
  <div class="picker-anchor">
    <EmojiPicker onpick={pickFromPicker} onclose={() => (pickerOpen = false)} />
  </div>
{/if}

{#if menuOpen}
  <div class="menu" role="menu">
    {#if mine}
      <button type="button" class="menu-item" role="menuitem" onclick={togglePin}>
        <NavIcon name="pin" filled={pinned} />
        <span>{pinned ? $t('status.unpin') : $t('status.pin')}</span>
      </button>
      <button
        type="button"
        class="menu-item danger"
        role="menuitem"
        onclick={remove}
        disabled={deleting}
      >
        <NavIcon name="trash" />
        <span>{$t('status.delete')}</span>
      </button>
    {:else}
      <button
        type="button"
        class="menu-item"
        role="menuitem"
        onclick={doReport}
        disabled={reported}
      >
        <NavIcon name="flag" />
        <span>{reported ? $t('status.reported') : $t('status.report')}</span>
      </button>
    {/if}
  </div>
{/if}

<style>
  .reactions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.25rem;
    margin-top: 0.5rem;
  }
  .reaction-chip {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    padding: 0.125rem 0.5rem;
    border-radius: 999px;
    background: var(--fill-soft);
    border: 1px solid transparent;
    font-size: 0.875rem;
    line-height: 1.4;
    cursor: pointer;
  }
  .reaction-chip:hover {
    background: var(--fill-hover);
  }
  /* 読み取り専用のときはボタンだが押せない ── 淡くならず、そのまま見せる。 */
  .reaction-chip:disabled {
    opacity: 1;
    cursor: default;
  }
  .reaction-chip:disabled:hover {
    background: var(--fill-soft);
  }
  .reaction-chip.me {
    background: var(--fill-active);
    border-color: var(--fill-active-edge);
  }
  .reaction-chip .emoji {
    font-size: 1rem;
  }
  .reaction-chip img.emoji {
    width: 1.125rem;
    height: 1.125rem;
    vertical-align: -0.2em;
  }
  .reaction-chip .count {
    font-variant-numeric: tabular-nums;
    color: var(--color-text-muted);
  }
  /* 押している状態は、地の色と字の濃さと、塗りつぶした星・栞で示す。
     グローバルの chip[aria-pressed] は地を暗く塗るので、ここで淡い行に
     合わせて上書きする ── 字が淡い地に溶けない(旧: 白字 on 薄灰 ≒1.3:1)。 */
  .status-actions .chip.active {
    color: var(--color-text);
    background: var(--fill-active);
    border-color: var(--fill-active-edge);
    font-weight: 600;
  }
  /* 行の中のアイコンは本文より一回り小さく。字と同じ重さで並ぶように。 */
  .status-actions :global(.nav-ico) {
    width: 1.2em;
    height: 1.2em;
  }
  .status-actions .bookmark {
    margin-left: auto;
  }
  .picker-anchor {
    position: relative;
    margin-top: 0.25rem;
  }

  /* 🔁 ボタンとその小メニューの入れもの。メニューをこのボタンの
     真下に絶対配置で吊るすための基準。 */
  .boost-wrap {
    position: relative;
    display: inline-flex;
  }
  .boost-menu {
    position: absolute;
    top: 100%;
    left: 0;
    z-index: 10;
  }

  .menu {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 0.125rem;
    margin-top: 0.25rem;
    padding: 0.25rem;
    width: max-content;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
  }
  .menu-item {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.375rem 0.5rem;
    border: none;
    border-radius: var(--radius-sm);
    background: none;
    font: inherit;
    color: inherit;
    text-align: left;
    cursor: pointer;
  }
  .menu-item :global(.nav-ico) {
    width: 1.15em;
    height: 1.15em;
  }
  .menu-item:hover:not(:disabled) {
    background: var(--fill-hover);
  }
  .menu-item.active {
    background: var(--fill-active);
  }
  .menu-item.danger:hover:not(:disabled) {
    background: var(--fill-danger);
  }
  .menu-item:disabled {
    opacity: 0.6;
    cursor: default;
  }
</style>
