<script lang="ts">
  import { getLists, getListAccounts, addToList, removeFromList, type List } from '#lib/api.js';
  import { refreshCircles } from '#lib/circles.js';
  import { t } from '#lib/i18n.js';
  import { dismissable } from '#lib/ux/dismiss.js';

  // フォローとは別の「この人を名簿(リスト/サークル)に入れる」口。開いたとき
  // リスト一覧と所属を読み、チェックでその場で add / remove する。フォローは
  // 触らない（サークルはフォローと独立した名簿だから）。
  let { accountId }: { accountId: string } = $props();

  let open = $state(false);
  let lists = $state<List[]>([]);
  let memberOf = $state<Set<string>>(new Set());
  let loaded = $state(false);
  let busy = $state<string | null>(null);

  async function toggleOpen() {
    open = !open;
    if (open && !loaded) await load();
  }

  async function load() {
    try {
      const ls = await getLists();
      // 各リストにこの人が入っているか。個人インスタンスならリストは数個なので
      // 素朴に全リストのメンバーを引いて判定する。
      const flags = await Promise.all(
        ls.map(async (l) => (await getListAccounts(l.id)).some((a) => a.id === accountId))
      );
      lists = ls;
      memberOf = new Set(ls.filter((_, i) => flags[i]).map((l) => l.id));
      loaded = true;
    } catch {
      // 取れなければ閉じておく。開き直せばまた試す。
      open = false;
    }
  }

  async function toggle(l: List) {
    if (busy) return;
    busy = l.id;
    const has = memberOf.has(l.id);
    try {
      if (has) {
        await removeFromList(l.id, [accountId]);
        memberOf.delete(l.id);
      } else {
        await addToList(l.id, [accountId]);
        memberOf.add(l.id);
      }
      memberOf = new Set(memberOf); // 再代入でリアクティブに
      void refreshCircles();
    } catch {
      // 失敗時はそのまま（checked は memberOf に描き戻る）。
    } finally {
      busy = null;
    }
  }
</script>

<div class="add-to-list" {@attach dismissable(() => open, () => (open = false))}>
  <button type="button" class="chip" aria-haspopup="menu" aria-expanded={open} onclick={toggleOpen}>
    {$t('lists.addTo')}
  </button>
  {#if open}
    <div class="menu" role="menu">
      {#if !loaded}
        <p class="prose-small">{$t('common.loading')}</p>
      {:else if lists.length === 0}
        <p class="prose-small">{$t('lists.empty')}</p>
      {:else}
        {#each lists as l (l.id)}
          <label class="row">
            <input
              type="checkbox"
              checked={memberOf.has(l.id)}
              disabled={busy === l.id}
              onchange={() => toggle(l)}
            />
            <span>{l.title}</span>
          </label>
        {/each}
      {/if}
    </div>
  {/if}
</div>

<style>
  .add-to-list {
    position: relative;
    display: inline-block;
  }
  .menu {
    position: absolute;
    right: 0;
    z-index: 10;
    margin-top: 0.25rem;
    min-width: 12rem;
    max-width: calc(100vw - 2rem);
    padding: 0.25rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.375rem 0.5rem;
    cursor: pointer;
  }
  .row:hover {
    background: var(--fill-hover);
  }
</style>
