<script lang="ts">
  // アカウント選択の窓。一度ログインしたことのあるアカウントの中から
  // ひとつを選ぶ。条件を満たす行(role が admin)は、地・罫線・字を
  // 濃くして静かに強調する ── 条件そのものは呼び元が決め、ここには
  // emphasized だけが乗ってくる。
  //
  // 選んだあとは、行ごとの <form> がそのまま action へ POST する。
  // トークンを JS で DOM に組み立てず、既存の貼り付けログインと同じ
  // 道を通す。
  import Avatar from './Avatar.svelte';
  import { useOverlay } from '#lib/ux/overlay.svelte.js';

  type Choice = {
    acct: string;
    display_name: string;
    avatar: string | null;
    token: string;
    emphasized: boolean;
  };

  let {
    title,
    hint,
    badge,
    cancelLabel,
    action,
    accounts,
    onclose
  }: {
    title: string;
    hint: string;
    badge: string;
    cancelLabel: string;
    action: string;
    accounts: Choice[];
    onclose: () => void;
  } = $props();

  // 開いている間だけ在る窓。Esc でも、戻る(Android)でも閉じる。
  useOverlay(() => true, () => onclose());
</script>

<div
  class="picker-backdrop"
  role="dialog"
  aria-modal="true"
  aria-label={title}
  tabindex="-1"
>
  <div class="picker-panel">
    <p class="picker-title">{title}</p>
    <p class="picker-hint muted">{hint}</p>

    <ul class="picker-list">
      {#each accounts as a (a.acct)}
        <li>
          <form method="post" {action}>
            <input type="hidden" name="token" value={a.token} />
            <button type="submit" class="picker-row" class:emphasized={a.emphasized}>
              <Avatar class="avatar" src={a.avatar} name={a.display_name || a.acct} />
              <span class="picker-id">
                <span class="picker-name">{a.display_name || `@${a.acct}`}</span>
                {#if a.display_name}<span class="picker-acct muted">@{a.acct}</span>{/if}
              </span>
              {#if a.emphasized}<span class="picker-badge">{badge}</span>{/if}
            </button>
          </form>
        </li>
      {/each}
    </ul>

    <div class="picker-actions">
      <button type="button" class="chip" onclick={onclose}>{cancelLabel}</button>
    </div>
  </div>
</div>

<style>
  /* 画面いっぱいに薄い幕を引いて、その上に小さな卓を置く。 */
  .picker-backdrop {
    position: fixed;
    inset: 0;
    z-index: var(--layer-overlay);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: var(--space-4);
    background: var(--color-scrim);
  }
  .picker-panel {
    width: min(92vw, 360px);
    max-height: 80vh;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    padding: var(--space-4);
    background: var(--color-bg);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
  }
  .picker-title {
    font-weight: 600;
  }
  .picker-hint {
    margin: 0;
  }
  .picker-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .picker-list form {
    margin: 0;
  }
  /* 一行 = ひとつのアカウント選択。素の面・淡い字で、条件を満たす
     行だけが強調される。 */
  .picker-row {
    width: 100%;
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-3);
    font: inherit;
    text-align: start;
    color: var(--color-text-muted);
    background: transparent;
    border: 1px solid transparent;
    border-radius: var(--radius-sm);
    cursor: pointer;
  }
  .picker-row:hover {
    color: var(--color-text);
    border-color: var(--color-border-strong);
  }
  .picker-row.emphasized {
    color: var(--color-text);
    background: var(--fill-soft);
    border-color: var(--color-text);
    font-weight: 600;
  }
  .picker-id {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .picker-name {
    overflow-wrap: anywhere;
  }
  .picker-acct {
    font-size: var(--text-sm);
    font-weight: 400;
  }
  .picker-badge {
    margin-inline-start: auto;
    flex-shrink: 0;
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-text);
    border: 1px solid var(--color-text);
    border-radius: 999px;
    padding: 1px var(--space-2);
  }
  .picker-actions {
    display: flex;
    justify-content: flex-end;
  }
</style>
