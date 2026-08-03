<script lang="ts">
  // 管理者がみんなに貼った「おしらせ」。ログイン中の人にだけ、下に
  // そっと浮かぶ。UpdateBanner / EmailNudge と同じ非モーダルのカード ─
  // 画面は塞がない。まだ読んでいない(read=false)ものだけを、新しい順に
  // 一枚ずつ出す。「わかりました」で dismiss すると、その人の中では
  // 静かになる(サーバが覚えるので、別の端末でも出てこない)。
  //
  // 一度に全部は出さない。一枚に集中して、閉じたら次の一枚。溜まって
  // いても急かさない。
  import { onMount } from 'svelte';
  import { afterNavigate } from '$app/navigation';
  import { isLoggedIn } from '$lib/auth';
  import { getAnnouncements, dismissAnnouncement, type Announcement } from '$lib/api';
  import { t } from '$lib/i18n';

  let queue = $state<Announcement[]>([]);
  let busy = $state(false);
  // 一度 token 付きで読んだら、ナビのたびに取り直さない。ログイン直後
  // (SPA ナビで layout が残るケース)だけ afterNavigate で拾い直す。
  let loaded = false;

  let current = $derived(queue[0] ?? null);

  async function load() {
    if (!isLoggedIn()) return;
    loaded = true;
    try {
      const all = await getAnnouncements();
      queue = all.filter((a) => !a.read);
    } catch {
      // 読めなかったら、出さない。次の機会に。
    }
  }

  onMount(() => void load());
  afterNavigate(() => {
    if (!loaded && isLoggedIn()) void load();
  });

  async function dismiss() {
    if (busy || !current) return;
    busy = true;
    const id = current.id;
    try {
      await dismissAnnouncement(id);
      queue = queue.filter((a) => a.id !== id);
    } catch {
      // 届かなくても、いまは黙って閉じる(次の load でまた拾える)。
      queue = queue.filter((a) => a.id !== id);
    } finally {
      busy = false;
    }
  }
</script>

{#if current}
  <aside class="announce" role="status" aria-live="polite" aria-label={$t('announce.label')}>
    <!-- 中身は管理者が書いたもの。HTML はそのまま見せる。 -->
    <div class="body">{@html current.content}</div>
    <div class="actions">
      <button type="button" class="btn px-3 py-1" disabled={busy} onclick={() => void dismiss()}>
        {$t('announce.dismiss')}
      </button>
    </div>
  </aside>
{/if}

<style>
  /* 流れの中に置く(EmailNudge と同じ理由)。三つとも同じ bottom と
     z-index で浮いていたので、二つ出たときは互いに重なっていた。 */
  .announce {
    max-width: 24rem;
    margin-inline: auto;
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius);
    font-size: var(--text-sm);
    display: grid;
    gap: var(--space-2);
  }

  .body {
    line-height: 1.6;
  }

  .body :global(p) {
    margin: 0 0 var(--space-2);
  }

  .body :global(p:last-child) {
    margin-bottom: 0;
  }

  .actions {
    display: flex;
    gap: var(--space-2);
    justify-content: flex-end;
  }
</style>
