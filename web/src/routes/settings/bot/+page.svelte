<script lang="ts">
  // 手だけのアカウント(bot)を、admin がつくる／鍵を取り替える。
  // 鍵が見えるのは返事のその一回だけ。閉じたら、もう出てこない。
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { isLoggedIn } from '$lib/auth';
  import { createBot, rotateBotToken, type BotTokenResponse } from '$lib/api';
  import { t } from '$lib/i18n';

  let username = $state('');
  let displayName = $state('');
  let rotateId = $state('');
  let busy = $state(false);
  let error = $state<string | null>(null);
  let result = $state<BotTokenResponse | null>(null);

  onMount(() => {
    if (!isLoggedIn()) void goto('/');
  });

  async function run(action: () => Promise<BotTokenResponse>) {
    if (busy) return;
    busy = true;
    error = null;
    result = null;
    try {
      result = await action();
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      error = msg === 'admin_required' ? $t('bot.adminRequired') : $t('bot.failed');
    } finally {
      busy = false;
    }
  }
</script>

<section class="hero">
  <h1>{$t('bot.title')}</h1>
</section>
<p class="prose-small">{$t('bot.help')}</p>

{#if error}
  <p class="error">{error}</p>
{/if}

{#if result}
  <p class="notice">{$t('bot.tokenOnce')}</p>
  <p class="prose-small">@{result.account.acct}</p>
  <p><code>{result.token}</code></p>
{/if}

<h2>{$t('bot.createTitle')}</h2>
<form
  class="form stack"
  onsubmit={(e) => {
    e.preventDefault();
    void run(() => createBot(username, displayName));
  }}
>
  <label class="stack-tight">
    <span>{$t('bot.username')}</span>
    <input type="text" bind:value={username} autocomplete="off" required />
  </label>
  <label class="stack-tight">
    <span>{$t('bot.displayName')}</span>
    <input type="text" bind:value={displayName} autocomplete="off" />
  </label>
  <button type="submit" class="btn px-6 py-2" disabled={busy}>{$t('bot.create')}</button>
</form>

<h2>{$t('bot.rotateTitle')}</h2>
<form
  class="form stack"
  onsubmit={(e) => {
    e.preventDefault();
    void run(() => rotateBotToken(rotateId));
  }}
>
  <label class="stack-tight">
    <span>{$t('bot.id')}</span>
    <input type="text" bind:value={rotateId} inputmode="numeric" autocomplete="off" required />
  </label>
  <button type="submit" class="btn px-6 py-2" disabled={busy}>{$t('bot.rotate')}</button>
</form>

<p class="prose-small"><a href="/settings">{$t('security.backToSettings')}</a></p>
