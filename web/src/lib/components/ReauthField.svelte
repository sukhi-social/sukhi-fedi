<script lang="ts">
  // 要素を外す操作の「本人確認」欄。あいことばを持つ人には password
  // 入力を、持たない人(いまの標準)には「コードを送る→6桁入力」を
  // 出す。親はバインドされた password / reauthCode を Reauth 型に
  // 詰めてサーバへ渡すだけ。
  import { requestReauthCode } from '#lib/auth.js';
  import { t } from '#lib/i18n.js';

  let {
    hasPassword,
    password = $bindable(''),
    reauthCode = $bindable('')
  }: { hasPassword: boolean; password?: string; reauthCode?: string } = $props();

  let sent = $state(false);
  let busy = $state(false);
  let error = $state<string | null>(null);

  async function send() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      await requestReauthCode();
      sent = true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      error =
        msg === 'rate_limited'
          ? $t('login.rateLimited')
          : msg === 'no_verified_email'
            ? $t('security.noVerifiedEmail')
            : $t('common.deliverFailed');
    } finally {
      busy = false;
    }
  }
</script>

{#if hasPassword}
  <label class="stack-tight">
    <span>{$t('security.passwordToConfirm')}</span>
    <input type="password" bind:value={password} autocomplete="current-password" required />
  </label>
{:else}
  <div class="stack-tight">
    <span>{$t('security.reauthLabel')}</span>
    {#if sent}
      <p class="help">{$t('security.codeSent')}</p>
      <input
        type="text"
        bind:value={reauthCode}
        inputmode="numeric"
        autocomplete="one-time-code"
        pattern="[0-9]{'{6}'}"
        placeholder={$t('login.code')}
        required
      />
      <p>
        <button type="button" class="chip" disabled={busy} onclick={() => void send()}
          >{$t('login.sendAgain')}</button
        >
      </p>
    {:else}
      <p class="help">{$t('security.reauthHelp')}</p>
      <p>
        <button type="button" class="chip" disabled={busy} onclick={() => void send()}
          >{$t('security.reauthSend')}</button
        >
      </p>
    {/if}
    {#if error}
      <p class="error">{error}</p>
    {/if}
  </div>
{/if}

<style>
  p {
    margin: 0;
  }
</style>
