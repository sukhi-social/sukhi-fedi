<script lang="ts">
  // アカウントの引っ越し(Mastodon Move + alsoKnownAs)。静かに。
  // 別名(これも自分)を編集でき、そろったら引っ越せる。引っ越し済みなら
  // 行き先だけを素直に出す ─ 数字も、煽りも、アニメーションもなし。
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { getMigration, setAliases, moveAccount } from '#lib/api.js';
  import { clearToken, isLoggedIn } from '#lib/auth.js';
  import { t, type TranslationKey } from '#lib/i18n.js';

  const MAX_ALIASES = 5;

  let aliases = $state<string[]>([]);
  let movedTo = $state<string | null>(null);
  let moveTarget = $state('');

  let loading = $state(true);
  let savingAliases = $state(false);
  let aliasesSaved = $state(false);
  let moving = $state(false);
  let error = $state<string | null>(null);
  let moveError = $state<string | null>(null);

  onMount(() => {
    if (!isLoggedIn()) {
      void goto('/');
      return;
    }
    void load();
  });

  async function load() {
    loading = true;
    error = null;
    try {
      const m = await getMigration();
      aliases = m.aliases ?? [];
      movedTo = m.moved_to ?? null;
    } catch (e) {
      if (onAuthError(e)) return;
      error = $t('common.readFailed');
    } finally {
      loading = false;
    }
  }

  function onAuthError(e: unknown): boolean {
    if (e instanceof Error && e.message === 'unauthorized') {
      clearToken();
      void goto('/');
      return true;
    }
    return false;
  }

  function addAlias() {
    if (aliases.length < MAX_ALIASES) aliases = [...aliases, ''];
  }

  function removeAlias(i: number) {
    aliases = aliases.filter((_, idx) => idx !== i);
  }

  async function saveAliases() {
    if (savingAliases) return;
    savingAliases = true;
    error = null;
    aliasesSaved = false;
    try {
      const cleaned = aliases.map((a) => a.trim()).filter((a) => a !== '');
      const res = await setAliases(cleaned);
      aliases = res.aliases ?? [];
      aliasesSaved = true;
    } catch (e) {
      if (onAuthError(e)) return;
      error = $t('migration.err.generic');
    } finally {
      savingAliases = false;
    }
  }

  async function doMove() {
    const target = moveTarget.trim();
    if (!target || moving) return;
    if (!confirm($t('migration.moveConfirm'))) return;
    moving = true;
    moveError = null;
    try {
      const res = await moveAccount(target);
      movedTo = res.moved_to ?? null;
    } catch (e) {
      if (onAuthError(e)) return;
      const code = e instanceof Error ? e.message : '';
      moveError = $t(moveErrorKey(code));
    } finally {
      moving = false;
    }
  }

  // サーバが返すエラーコードを、こちらで言える言い方に対応づける。知らない
  // コードは generic に落とす ─ 言える分だけ静かに言う。
  function moveErrorKey(code: string): TranslationKey {
    switch (code) {
      case 'target_must_alias_back':
        return 'migration.err.target_must_alias_back';
      case 'invalid_target':
        return 'migration.err.invalid_target';
      case 'already_moved':
        return 'migration.err.already_moved';
      default:
        return 'migration.err.generic';
    }
  }
</script>

<header class="timeline page-head">
  <h1>{$t('migration.title')}</h1>
</header>

{#if loading}
  <p class="loading">{$t('common.loading')}</p>
{:else}
  <section class="settings-form">
    <p class="muted">{$t('migration.intro')}</p>

    {#if movedTo}
      <p class="prose-small" style="margin-top: var(--space-4);">
        {$t('migration.moved')}
        <a href={movedTo} target="_blank" rel="noopener noreferrer">{movedTo}</a>
      </p>
    {/if}

    <div class="stack-tight" style="margin-top: var(--space-5);">
      <h2 class="text-base">{$t('migration.aliasesTitle')}</h2>
      <p class="muted text-sm">{$t('migration.aliasesHelp')}</p>

      {#if aliases.length === 0}
        <p class="prose-small">{$t('migration.aliasesNone')}</p>
      {/if}

      {#each aliases as _alias, i (i)}
        <div class="alias-row">
          <input
            type="url"
            bind:value={aliases[i]}
            maxlength="512"
            placeholder={$t('migration.aliasPlaceholder')}
            aria-label={$t('migration.aliasesTitle')}
          />
          <button type="button" class="chip" onclick={() => removeAlias(i)}>
            {$t('migration.aliasRemove')}
          </button>
        </div>
      {/each}

      {#if aliases.length < MAX_ALIASES}
        <button type="button" class="chip" onclick={addAlias}>{$t('migration.aliasAdd')}</button>
      {/if}

      <div class="hstack" style="--gap: var(--space-3)">
        <button type="button" class="btn px-6 py-2" disabled={savingAliases} onclick={saveAliases}>
          {savingAliases ? $t('settings.saving') : $t('settings.save')}
        </button>
        {#if aliasesSaved}
          <span class="muted">{$t('migration.aliasesSaved')}</span>
        {/if}
      </div>

      {#if error}
        <p class="error">{error}</p>
      {/if}
    </div>

    {#if !movedTo}
      <div class="stack-tight" style="margin-top: var(--space-6);">
        <h2 class="text-base">{$t('migration.moveTitle')}</h2>
        <p class="muted text-sm">{$t('migration.moveHelp')}</p>
        <input
          type="url"
          bind:value={moveTarget}
          maxlength="512"
          placeholder={$t('migration.movePlaceholder')}
          aria-label={$t('migration.moveTitle')}
        />
        <div>
          <button type="button" class="btn px-6 py-2" disabled={moving} onclick={doMove}>
            {$t('migration.moveButton')}
          </button>
        </div>
        {#if moveError}
          <p class="error">{moveError}</p>
        {/if}
      </div>
    {/if}

    <p class="prose-small" style="margin-top: var(--space-5);">
      <a class="chip" href="/settings">{$t('security.backToSettings')}</a>
    </p>
  </section>
{/if}

<style>
  /* 別名の編集行。URL 入力を広く、消すボタンを横に。狭い幅では折り返す。 */
  .alias-row {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    align-items: center;
  }
  .alias-row input {
    flex: 1 1 12rem;
    min-width: 0;
  }
</style>
