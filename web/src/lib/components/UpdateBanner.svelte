<script lang="ts">
  // SvelteKit が `_app/version.json` を kit.version.pollInterval ごと
  // に取りに行く。サーバ側で新しいビルドが配られて version 文字列が
  // 変わると `$updated` (boolean ストア) が true になるので、その
  // 瞬間に静かに「リロードしますか?」を出す。
  //
  // 以前 `$updated.current` を見ていたが、`$app/stores` の updated は
  // ただの boolean ストアで `.current` プロパティは無い。これに気付か
  // ず本番にいて、新版が降りてもバナーが出ない状態がしばらく続いた。
  // (`.current` 形は `$app/state` 側のもので、別の API。)
  //
  // 即時 reload で押し付けない理由:
  // - 入力中だったり読書中だったりすると失礼
  // - ユーザの「いま」を尊重する
  //
  // 出したあと、ユーザがリロードを選ばないまま放っておくと、
  // SvelteKit はリンクを踏んだ瞬間に invalidateAll してくれるので、
  // バナーを無視しても通常操作で必ず追いつく(壊れる前に)。
  import { updated } from '$app/stores';
  import { swWaiting } from '$lib/pwa';
  import { t } from '$lib/i18n';

  // 「読み込みなおす」で、待っている service worker も一緒に代える。
  //
  // ただ reload するだけだと、新しいページを配るのは**古い worker**の
  // まま ── 新しいほうは全部のタブが閉じるまで待ちつづける。ページの
  // 見た目は新しくなるのに worker のふるまいは古いままで、その差が
  // いちばん出るのが push だった(通知の畳みかたを直した日に、直って
  // いない worker が鳴らし続けた)。
  //
  // 自動では代えない。押されたときだけ合図を送って、代わったのを見て
  // から読み込みなおす ── 入口は、この釦ひとつのまま。
  async function reload() {
    try {
      const reg = await navigator.serviceWorker?.getRegistration();
      if (reg?.waiting) {
        navigator.serviceWorker.addEventListener(
          'controllerchange',
          () => window.location.reload(),
          { once: true }
        );
        reg.waiting.postMessage({ type: 'skip-waiting' });
        return;
      }
    } catch {
      // service worker が居ない・触れないブラウザ。ふつうに読み込む。
    }
    window.location.reload();
  }

  let show = $state(false);

  function dismiss() {
    // 一度閉じても polling は続くので、本当に新しい版が来たら
    // 次の interval で再表示される。明示的に消したいときは
    // sessionStorage に印を残せばよい(今は不要)。
    show = false;
  }

  // 版が変わったとき、**または** worker だけが代わりを待っているとき。
  // 後者は $updated が動かないので、これが無いと worker のふるまいの
  // 直しは全部のタブが閉じるまで誰にも届かない。
  $effect(() => {
    if ($updated || $swWaiting) show = true;
  });
</script>

{#if show}
  <aside class="update-banner" role="status" aria-live="polite">
    <p>{$t('update.available')}</p>
    <div class="actions">
      <button type="button" class="btn px-3 py-1" onclick={reload}>{$t('update.reload')}</button>
      <button type="button" class="btn secondary px-3 py-1" onclick={dismiss}>{$t('update.later')}</button>
    </div>
  </aside>
{/if}

<style>
  /* 流れの中に置く(EmailNudge と同じ理由)。浮かせていたときは、下の
     タブ帯とも重なっていた ── 持ち上げていたのは .email-nudge だけ。 */
  .update-banner {
    max-width: 24rem;
    margin-inline: auto;
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius);
    display: flex;
    gap: var(--space-4);
    align-items: center;
    justify-content: space-between;
    font-size: var(--text-sm);
  }

  .update-banner p {
    margin: 0;
  }

  .actions {
    display: flex;
    gap: var(--space-2);
    flex-shrink: 0;
  }
</style>
