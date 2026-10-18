<script lang="ts">
  import {
    followAccount,
    unfollowAccount,
    type Relationship
  } from '#lib/api.js';
  import { clearToken, isLoggedIn } from '#lib/auth.js';
  import { goto } from '$app/navigation';
  import { t } from '#lib/i18n.js';

  let {
    accountId,
    // null = まだ取れていない / 自分自身 などで「ボタンを出さない」
    relationship,
    onchange
  }: {
    accountId: string;
    relationship: Relationship | null;
    onchange?: (r: Relationship) => void;
  } = $props();

  let pending = $state(false);
  let error = $state<string | null>(null);

  // ボタン自身が持つ最新の relationship。prop から初期化して、
  // follow / unfollow が返ってきたら上書きする。prop 直バインドだと、
  // 親がこの relationship を保持し直さないかぎり「フォロー」のまま
  // 動かなくなる。
  let current = $state<Relationship | null>(relationship);

  // prop が外から差し替わったら追従。$effect で同期。
  $effect(() => {
    current = relationship;
  });

  // `state` という名前は rune `$state` の解析と衝突するのでズラす。
  let currentState = $derived(
    current?.following
      ? 'following'
      : current?.requested
        ? 'requested'
        : 'idle'
  );

  let label = $derived(
    currentState === 'following'
      ? $t('follow.following')
      : currentState === 'requested'
        ? $t('follow.requested')
        : $t('follow.follow')
  );

  async function toggle() {
    if (!isLoggedIn()) {
      void goto('/');
      return;
    }
    if (pending || !current) return;
    pending = true;
    error = null;
    try {
      const r =
        currentState === 'following' || currentState === 'requested'
          ? await unfollowAccount(accountId)
          : await followAccount(accountId);
      current = r;
      onchange?.(r);
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        void goto('/');
        return;
      }
      error = $t('common.deliverFailed');
    } finally {
      pending = false;
    }
  }
</script>

{#if current}
  <button
    type="button"
    class="follow-btn"
    data-state={currentState}
    onclick={toggle}
    disabled={pending}
  >
    {pending ? '…' : label}
  </button>
  {#if error}
    <span class="error text-sm">{error}</span>
  {/if}
{/if}
