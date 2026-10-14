<script lang="ts">
  // 自分の鍵を足す(名前と期限つき)／管理者が手だけのアカウント(bot)を
  // つくる・鍵を取り替える。鍵が見えるのは返事のその一回だけ。
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { isLoggedIn } from '$lib/auth';
  import {
    createBot,
    rotateBotToken,
    issuePersonalToken,
    type BotTokenResponse,
    type PersonalToken
  } from '$lib/api';
  import { t } from '$lib/i18n';

  let tokenName = $state('');
  let expiresInDays = $state(90);
  let mine = $state<PersonalToken | null>(null);
  let username = $state('');
  let displayName = $state('');
  let rotateId = $state('');
  let busy = $state(false);
  let error = $state<string | null>(null);
  let result = $state<BotTokenResponse | null>(null);

  onMount(() => {
    if (!isLoggedIn()) void goto('/');
  });

  async function run<T>(action: () => Promise<T>): Promise<T | null> {
    if (busy) return null;
    busy = true;
    error = null;
    result = null;
    mine = null;
    try {
      return await action();
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      error = msg === 'admin_required' ? $t('bot.adminRequired') : $t('bot.failed');
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

{#if result}
  <p class="notice">{$t('bot.tokenOnce')}</p>
  <p class="prose-small">@{result.account.acct}</p>
  <p><code>{result.token}</code></p>
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

<h2>{$t('bot.adminTitle')}</h2>
<h3>{$t('bot.createTitle')}</h3>
<form
  class="form stack"
  onsubmit={(e) => {
    e.preventDefault();
    void run(() => createBot(username, displayName)).then((r) => (result = r));
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

<h3>{$t('bot.rotateTitle')}</h3>
<form
  class="form stack"
  onsubmit={(e) => {
    e.preventDefault();
    void run(() => rotateBotToken(rotateId)).then((r) => (result = r));
  }}
>
  <label class="stack-tight">
    <span>{$t('bot.id')}</span>
    <input type="text" bind:value={rotateId} inputmode="numeric" autocomplete="off" required />
  </label>
  <button type="submit" class="btn px-6 py-2" disabled={busy}>{$t('bot.rotate')}</button>
</form>

<p class="prose-small"><a href="/settings">{$t('security.backToSettings')}</a></p>
