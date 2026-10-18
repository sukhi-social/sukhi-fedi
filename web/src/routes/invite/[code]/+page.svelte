<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { saveSignupDraft } from '#lib/auth.js';
  import { t } from '#lib/i18n.js';
  import LangSwitch from '#lib/components/LangSwitch.svelte';

  let code = $derived(page.params.code ?? '');

  // サーバの確認結果。valid の二択 ─ 生きていれば誰が招いたか、
  // そうでなければ理由(used/expired/invalid)だけ。
  type Preview = 
    { 
      valid: true;
      issuer_handle: string | null;
      issuer_display_name: string | null
     } |
    { valid: false; reason: string };

  let phase = $state<'loading' | 'ok' | 'dead' | 'error'>('loading');
  let issuer = $state<string | null>(null);
  let reason = $state<'invalid' | 'already_used' | 'expired'>('invalid');

  // このブラウザから見たサーバ名。玄関の「ようこそ、◯◯ へ」に使う。
  const host = $derived(typeof window !== 'undefined' ? window.location.host : '');

  // 生きていないコードの理由 → 文言キー。i18n の鍵は型で縛られるので、
  // テンプレートリテラルではなく明示的に選ぶ。
  const deadKey = $derived(
    reason === 'already_used'
      ? 'invite.dead.already_used'
      : reason === 'expired'
        ? 'invite.dead.expired'
        : 'invite.dead.invalid'
  );

  onMount(async () => {
    try {
      const res = await fetch(`/api/v1/invite/${encodeURIComponent(code)}`);
      if (!res.ok) {
        phase = 'error';
        return;
      }
      const data = await res.json() as Preview;
      if (data.valid) {
        // 表示名があればそれ、無ければ @ハンドル、どちらも無ければ
        // 名前を伏せて「招待されています」だけ出す。
        const name = data.issuer_display_name?.trim();
        issuer = name || (data.issuer_handle ? '@' + data.issuer_handle : null);
        phase = 'ok';
      } else {
        reason =
          data.reason === 'already_used' || data.reason === 'expired' ? data.reason : 'invalid';
        phase = 'dead';
      }
    } catch {
      phase = 'error';
    }
  });

  // 「参加する」: コードを下書きに積んで /signup へ。signup ページは
  // onMount で invite_code を拾って欄を埋める(既存のしくみ)。メールと
  // なまえは玄関では分からないので空のまま ─ そこは signup で入れてもらう。
  function join() {
    saveSignupDraft({ username: '', invite_code: code, email: '' });
    goto('/signup');
  }
</script>

<section class="hero">
  {#if phase === 'loading'}
    <p class="tagline">{$t('invite.checking')}</p>
  {:else if phase === 'ok'}
    <h1>{$t('invite.welcomePre')}{host}{$t('invite.welcomePost')}</h1>
    <p class="tagline">
      {#if issuer}{$t('invite.invitedBy', { who: issuer })}{:else}{$t('invite.invitedAnon')}{/if}
    </p>
  {:else if phase === 'dead'}
    <h1>{$t('invite.deadTitle')}</h1>
    <p class="tagline">{$t(deadKey)}</p>
  {:else}
    <p class="tagline">{$t('invite.error')}</p>
  {/if}
</section>

{#if phase === 'ok'}
  <section class="section text-center">
    <p class="prose-small">{$t('invite.intro')}</p>
    <button type="button" class="btn px-6 py-2" onclick={join} style="margin-top: var(--space-3);"
      >{$t('invite.join')}</button
    >
  </section>
  <p class="prose-small text-center">
    {$t('signup.haveAccountPre')}<a href="/login">{$t('signup.haveAccountLink')}</a>{$t(
      'signup.haveAccountPost'
    )}
  </p>
{:else if phase === 'dead'}
  <p class="prose-small text-center">{$t('invite.deadHelp')}</p>
  <p class="prose-small text-center">
    <a href="/signup">{$t('invite.toSignup')}</a>
  </p>
{:else if phase === 'error'}
  <section class="section text-center">
    <button type="button" class="btn px-6 py-2" onclick={() => location.reload()}
      >{$t('invite.retry')}</button
    >
  </section>
{/if}

<section class="section" style="text-align: center; margin-top: var(--space-5);">
  <LangSwitch />
</section>
