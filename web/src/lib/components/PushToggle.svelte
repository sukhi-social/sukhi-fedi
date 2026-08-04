<script lang="ts">
  // 「知らせを受け取る」の一枚。
  //
  // ここから訊く ── 開いた瞬間にブラウザの許可を求めたりしない。押せる
  // のは人を起こせる唯一の道なので、始めるのは、その人の側。
  //
  // 何が鳴るかを、釦の前にちゃんと書く。押してから知るのは遅い。
  import { onMount } from 'svelte';
  import { createPush } from '$lib/push.svelte';
  import { t } from '$lib/i18n';

  const push = createPush();
  onMount(() => void push.refresh());
</script>

{#if push.state !== 'unsupported' && push.state !== 'unconfigured'}
  <section class="push-toggle timeline">
    <h2>{$t('push.title')}</h2>
    <p class="muted">{$t('push.what')}</p>
    <p class="muted">{$t('push.never')}</p>

    {#if push.state === 'denied'}
      <!-- ブラウザ側で断られている。ここからは戻せないので、そう言う。
           押しても何も起きない釦を出すより、正直なほうがいい。 -->
      <p class="prose-small">{$t('push.blocked')}</p>
    {:else if push.state === 'reauth'}
      <!-- いまの token に push の許しが無い。押させない ── 進めても、
           ブラウザの許可(一度しか訊けない)を使ったあとで断られるだけ。 -->
      <p class="prose-small">{$t('push.reauth')}</p>
    {:else if push.state === 'on'}
      <div class="push-row">
        <span class="prose-small">{$t('push.on')}</span>
        <button type="button" class="chip" onclick={() => void push.disable()}>
          {$t('push.stop')}
        </button>
      </div>
    {:else}
      <div class="push-row">
        <button
          type="button"
          class="btn px-6 py-2"
          disabled={push.state === 'working'}
          onclick={() => void push.enable()}
        >
          {push.state === 'working' ? $t('push.working') : $t('push.start')}
        </button>
      </div>
    {/if}

    {#if push.error}
      <p class="error">{$t('push.failed')}</p>
    {/if}
  </section>
{/if}

<style>
  .push-toggle {
    margin-top: var(--space-5);
  }

  .push-toggle h2 {
    font-size: var(--text-base);
  }

  .push-row {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    margin-top: var(--space-3);
  }
</style>
