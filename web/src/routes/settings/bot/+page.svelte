<script lang="ts">
  // 自分の鍵を足す(名前と期限つき)。鍵が見えるのは返事のその一回だけ。
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { isLoggedIn } from '$lib/auth';
  import { issuePersonalToken, type PersonalToken } from '$lib/api';
  import { t } from '$lib/i18n';

  let tokenName = $state('');
  let expiresInDays = $state(90);
  let mine = $state<PersonalToken | null>(null);
  let busy = $state(false);
  let error = $state<string | null>(null);

  onMount(() => {
    if (!isLoggedIn()) void goto('/');
  });

  async function run<T>(action: () => Promise<T>): Promise<T | null> {
    if (busy) return null;
    busy = true;
    error = null;
    mine = null;
    try {
      return await action();
    } catch {
      error = $t('bot.failed');
      return null;
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

{#if mine}
  <p class="notice">{$t('bot.tokenOnce')}</p>
  <p class="prose-small">{$t('bot.issuedFor', { name: mine.name, days: mine.expires_in_days })}</p>
  <p><code>{mine.token}</code></p>
{/if}

<h2>{$t('bot.mineTitle')}</h2>
<p class="prose-small">{$t('bot.mineHelp')}</p>
<form
  class="form stack"
  onsubmit={async (e) => {
    e.preventDefault();
    mine = await run(() => issuePersonalToken(tokenName, expiresInDays));
  }}
>
  <label class="stack-tight">
    <span>{$t('bot.tokenName')}</span>
    <input type="text" bind:value={tokenName} maxlength="40" autocomplete="off" required />
  </label>
  <label class="stack-tight">
    <span>{$t('bot.expires')}</span>
    <select bind:value={expiresInDays}>
      <option value={7}>{$t('bot.days7')}</option>
      <option value={30}>{$t('bot.days30')}</option>
      <option value={90}>{$t('bot.days90')}</option>
      <option value={365}>{$t('bot.days365')}</option>
    </select>
  </label>
  <button type="submit" class="btn px-6 py-2" disabled={busy}>{$t('bot.issue')}</button>
</form>

<p class="prose-small"><a href="/settings">{$t('security.backToSettings')}</a></p>
