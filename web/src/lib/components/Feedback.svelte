<script lang="ts">
  // 「意見を送る」。どの画面の隅にも在る小さなリンクで、押すと小さな
  // 窓が開く。窓は画面を塞がない(幕なし、aria-modal なし)── 読みながら
  // 書ける。Esc でも戻る(Android)でも閉じる(useOverlay)。
  //
  // 添えるのは screen(ルート名。ハンドルの入った URL ではない)・lang・
  // version だけ。ユーザーエージェントもアカウント名も送らない。
  // 失敗したら、何が起きたかと次の一手を言って、書いた文は残す。
  import { page } from '$app/state';
  import { sendFeedback } from '#lib/api.js';
  import { locale, t } from '#lib/i18n.js';
  import { useOverlay } from '#lib/ux/overlay.svelte.js';

  // 入る前後の導線では出さない。EmailNudge と同じ考えの、短い別の一覧。
  const QUIET_PREFIXES = ['/login', '/signup', '/check', '/app/callback'];

  const MAX = 2000;

  let open = $state(false);
  let text = $state('');
  let busy = $state(false);
  let error = $state<string | null>(null);
  let sent = $state(false);

  let quiet = $derived(QUIET_PREFIXES.some((p) => page.url.pathname.startsWith(p)));

  // ルート名(`/@[handle]` のような型)。URL そのものは使わない。
  const screen = () => (page.route.id ?? 'unknown').slice(0, 64);

  useOverlay(() => open, () => close());

  function close() {
    open = false;
    error = null;
    // 届いたあとに開きなおしたら、白い欄から。失敗したままなら文は残す。
    if (sent) {
      sent = false;
      text = '';
    }
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    const body = text.trim();
    if (body === '') {
      error = $t('feedback.empty');
      return;
    }
    if (body.length > MAX) {
      error = $t('feedback.tooLong');
      return;
    }
    busy = true;
    error = null;
    try {
      await sendFeedback({ body, screen: screen(), lang: $locale, version: __APP_VERSION__ });
      sent = true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : '';
      error = msg.endsWith('_429') ? $t('feedback.rateLimited') : $t('feedback.failed');
    } finally {
      busy = false;
    }
  }
</script>

{#if !quiet}
  <div class="feedback">
    <button type="button" class="feedback-open" aria-expanded={open} onclick={() => (open ? close() : (open = true))}>
      {$t('feedback.open')}
    </button>

    {#if open}
      <div class="feedback-card" role="dialog" aria-label={$t('feedback.title')}>
        <p class="feedback-title">{$t('feedback.title')}</p>
        {#if sent}
          <p role="status">{$t('feedback.thanks')}</p>
          <div class="feedback-actions">
            <button type="button" class="btn secondary px-3 py-1" onclick={close}>{$t('feedback.close')}</button>
          </div>
        {:else}
          <form onsubmit={submit}>
            <p class="feedback-hint">{$t('feedback.hint')}</p>
            <textarea
              bind:value={text}
              rows="5"
              maxlength={MAX}
              aria-label={$t('feedback.label')}
            ></textarea>
            {#if error}
              <p class="feedback-error" role="alert">{error}</p>
            {/if}
            <div class="feedback-actions">
              <button type="submit" class="btn px-3 py-1" disabled={busy}>
                {busy ? $t('common.sending') : $t('feedback.send')}
              </button>
              <button type="button" class="btn secondary px-3 py-1" onclick={close}>{$t('feedback.close')}</button>
            </div>
          </form>
        {/if}
      </div>
    {/if}
  </div>
{/if}

<style>
  .feedback {
    display: flex;
    justify-content: flex-end;
  }

  .feedback-open {
    min-height: var(--tap-min);
    padding-inline: var(--space-2);
    background: none;
    border: 0;
    color: var(--color-text-muted);
    font: inherit;
    font-size: var(--text-sm);
    text-decoration: underline;
    cursor: pointer;
  }

  /* 浮かせるが、幕は引かない。隅に小さく ── 後ろの画面は読めて、押せる。 */
  .feedback-card {
    position: fixed;
    inset-inline-end: var(--space-3);
    inset-block-end: var(--space-3);
    width: min(22rem, calc(100vw - 2 * var(--space-3)));
    max-height: calc(100dvh - 2 * var(--space-3));
    overflow: auto;
    z-index: var(--layer-overlay);
    padding: var(--space-3) var(--space-4);
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius);
    font-size: var(--text-sm);
    display: grid;
    gap: var(--space-2);
  }

  .feedback-card p,
  .feedback-card form {
    margin: 0;
  }

  form {
    display: grid;
    gap: var(--space-2);
  }

  .feedback-title {
    font-weight: 600;
  }

  .feedback-hint {
    color: var(--color-text-muted);
    font-size: 0.85em;
    line-height: 1.6;
  }

  .feedback-error {
    color: var(--color-danger);
  }

  textarea {
    width: 100%;
    box-sizing: border-box;
    resize: vertical;
  }

  .feedback-actions {
    display: flex;
    gap: var(--space-2);
    flex-wrap: wrap;
  }
</style>
