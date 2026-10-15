<script lang="ts">
  import { t } from '#lib/i18n.js';

  // タイムライン(home/public/tag/リスト)共通の表示フィルター。チェックを変えたら
  // onchange で親が頭から読み直す。hide_boosts は home でだけ意味があるので、
  // showHideBoosts で出し分ける(リストや public では出さない)。右寄せ。
  //
  // viewMode は「画像・メディアのみ」のときだけ出る、一覧↔写真の切り替え。
  // 同じ行を並べ替えるだけ(読み直さない)なので onchange は通さず、親が
  // bind で受けて描き分ける。showViewMode を立てた置き場だけに出す。
  let {
    onlyMedia = $bindable(false),
    hideBoosts = $bindable(false),
    hideSensitive = $bindable(false),
    viewMode = $bindable<'list' | 'photo'>('list'),
    showHideBoosts = false,
    showViewMode = false,
    // タブの行(nav.tabs)の中に置くとき。右端へ寄せ、chip の枠を消す。
    tabbed = false,
    onchange
  }: {
    onlyMedia?: boolean;
    hideBoosts?: boolean;
    hideSensitive?: boolean;
    viewMode?: 'list' | 'photo';
    showHideBoosts?: boolean;
    showViewMode?: boolean;
    tabbed?: boolean;
    onchange?: () => void;
  } = $props();

  let open = $state(false);
  let active = $derived(
    [onlyMedia, showHideBoosts && hideBoosts, hideSensitive].filter(Boolean).length
  );
</script>

<div class="filter-bar" class:in-tabs={tabbed}>
  <button
    type="button"
    class="chip"
    aria-expanded={open}
    aria-haspopup="menu"
    onclick={() => (open = !open)}
  >
    {$t('timeline.filter')}{active > 0 ? ` (${active})` : ''}
  </button>
  {#if open}
    <div class="filter-menu" role="menu">
      <label class="filter-row">
        <input type="checkbox" bind:checked={onlyMedia} onchange={() => onchange?.()} />
        <span>{$t('timeline.onlyMedia')}</span>
      </label>
      {#if showViewMode && onlyMedia}
        <!-- メディアのみのときだけ、一覧↔写真。同じ投稿を並べ替えるだけなので
             読み直さず、写真のときはサムネの壁になる。 -->
        <div class="view-mode" role="group" aria-label={$t('timeline.viewMode')}>
          <button
            type="button"
            class="chip"
            aria-pressed={viewMode === 'list'}
            onclick={() => (viewMode = 'list')}
          >
            {$t('timeline.viewList')}
          </button>
          <button
            type="button"
            class="chip"
            aria-pressed={viewMode === 'photo'}
            onclick={() => (viewMode = 'photo')}
          >
            {$t('timeline.viewPhoto')}
          </button>
        </div>
      {/if}
      {#if showHideBoosts}
        <label class="filter-row">
          <input type="checkbox" bind:checked={hideBoosts} onchange={() => onchange?.()} />
          <span>{$t('timeline.hideBoosts')}</span>
        </label>
      {/if}
      <label class="filter-row">
        <input type="checkbox" bind:checked={hideSensitive} onchange={() => onchange?.()} />
        <span>{$t('timeline.hideSensitive')}</span>
      </label>
    </div>
  {/if}
</div>

<style>
  /* 右寄せ。メニューは右端そろえで画面外に出さない。まわりとの間隔は
     置かれた側(.tabs の行内 / .stack のリズム)に任せる。 */
  .filter-bar {
    position: relative;
    display: flex;
    justify-content: flex-end;
  }
  /* タブの行の中では、右端へ寄せて、chip の枠は淡く消す(タブの下線と
     紛れないように。ホバーでも枠は出さない)。 */
  .filter-bar.in-tabs {
    margin-left: auto;
  }
  .in-tabs .chip,
  .in-tabs .chip:hover {
    border-color: transparent;
  }
  .filter-menu {
    position: absolute;
    top: 100%; /* ボタンの下に。指定しないと static 位置=ボタンに重なる */
    right: 0;
    z-index: 10;
    margin-top: 0.25rem;
    min-width: 14rem;
    max-width: calc(100vw - 2rem);
    padding: 0.25rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
  }
  .filter-row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.375rem 0.5rem;
    cursor: pointer;
  }
  .filter-row:hover {
    background: var(--fill-hover);
  }
  /* 一覧↔写真。フィルター行と同じ余白の中に、二つの chip を横に並べる。 */
  .view-mode {
    display: flex;
    gap: var(--space-2);
    padding: 0.375rem 0.5rem;
  }
</style>
