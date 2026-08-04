<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import {
    verifyCredentials,
    updateCredentials,
    setCurrentAccount,
    getBlocks,
    getMutes,
    unblockAccount,
    unmuteAccount,
    type Account
  } from '$lib/api';
  import { clearToken, isLoggedIn, loadToken } from '$lib/auth';
  import AccountActionRow from '$lib/components/AccountActionRow.svelte';
  import Avatar from '$lib/components/Avatar.svelte';
  import ImageCrop from '$lib/components/ImageCrop.svelte';
  import LangSwitch from '$lib/components/LangSwitch.svelte';
  import PushToggle from '$lib/components/PushToggle.svelte';
  import { t } from '$lib/i18n';

  let me = $state<Account | null>(null);
  // admin の「管理ページへ」ボタンが /admin/login に POST する bearer。
  // SPA がすでに持っている OAuth トークンをそのまま渡すので、トークンを
  // 貼り直す手間が要らない。
  let adminToken = $state('');
  let displayName = $state('');
  let note = $state('');
  let locked = $state(false);
  // 検索インデックスへの同意(FEP-5feb)。どちらも、はじめは「しない」。
  let discoverable = $state(false);
  let indexable = $state(false);
  // プロフィールのひとこと欄。本人が選んで置く、静かな key/value の行。
  // 連合するので、どの画面でも同じものが見える。最大 4 行。
  const MAX_FIELDS = 4;
  let fields = $state<{ name: string; value: string }[]>([]);

  function addField() {
    if (fields.length < MAX_FIELDS) fields = [...fields, { name: '', value: '' }];
  }

  function removeField(i: number) {
    fields = fields.filter((_, idx) => idx !== i);
  }
  let avatarFile = $state<File | null>(null);
  let headerFile = $state<File | null>(null);

  // 選んだファイルのプレビュー URL。$derived で作って、変わるたびに前のを revoke。
  let avatarPreview = $state<string | null>(null);
  let headerPreview = $state<string | null>(null);

  $effect(() => {
    if (!avatarFile) {
      avatarPreview = null;
      return;
    }
    const url = URL.createObjectURL(avatarFile);
    avatarPreview = url;
    return () => URL.revokeObjectURL(url);
  });

  $effect(() => {
    if (!headerFile) {
      headerPreview = null;
      return;
    }
    const url = URL.createObjectURL(headerFile);
    headerPreview = url;
    return () => URL.revokeObjectURL(url);
  });

  let loading = $state(true);
  let saving = $state(false);
  let error = $state<string | null>(null);
  let saved = $state(false);

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
      me = await verifyCredentials();
      adminToken = loadToken()?.access_token ?? '';
      displayName = me.display_name ?? '';
      // note は HTML で返ってくる。編集はテキストとして扱いたいので、
      // 雑だけど <br> を改行、その他のタグを落とす最小処理。
      // 自分が前に入れた素のテキストに近づけるだけで、サーバが正本。
      note = stripTags(me.note ?? '');
      locked = !!me.locked;
      discoverable = !!me.discoverable;
      indexable = !!me.indexable;
      // 値は HTML で返ってくる(リンクを含むことがある)。編集はテキストで
      // 扱いたいので、note と同じ最小処理でタグを落とす。サーバが正本。
      fields = (me.fields ?? []).map((f) => ({ name: stripTags(f.name), value: stripTags(f.value) }));
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        void goto('/');
        return;
      }
      error = $t('common.readFailed');
    } finally {
      loading = false;
    }
  }

  function stripTags(html: string): string {
    return html
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>\s*<p>/gi, '\n\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'");
  }

  // 画像を選ぶと、まず切り抜きの窓を開く。アバターは正方形(1:1)、
  // ヘッダーは横長(3:1、Mastodon の慣習)で切る。窓が返した File を
  // avatarFile / headerFile に入れれば、プレビューも保存も既存の流れに乗る。
  let cropTarget = $state<'avatar' | 'header' | null>(null);
  let cropSource = $state<File | null>(null);

  function onAvatar(ev: Event) {
    const input = ev.currentTarget as HTMLInputElement;
    const f = input.files?.[0] ?? null;
    // 同じ画像をもう一度選んでも change が鳴るように、値は空に戻す。
    input.value = '';
    if (!f) return;
    cropSource = f;
    cropTarget = 'avatar';
  }

  function onHeader(ev: Event) {
    const input = ev.currentTarget as HTMLInputElement;
    const f = input.files?.[0] ?? null;
    input.value = '';
    if (!f) return;
    cropSource = f;
    cropTarget = 'header';
  }

  function onCropDone(f: File) {
    if (cropTarget === 'avatar') avatarFile = f;
    else if (cropTarget === 'header') headerFile = f;
    cropTarget = null;
    cropSource = null;
  }

  function onCropCancel() {
    cropTarget = null;
    cropSource = null;
  }

  // ── ブロック / ミュート管理 ──────────────────────────────────────────
  // <details> を開いたとき一度だけ読む。サーバは全件返すのでページング無し。
  let blocks = $state<Account[]>([]);
  let mutes = $state<Account[]>([]);
  let relLoaded = $state(false);
  let relLoading = $state(false);
  let relError = $state<string | null>(null);

  function onRelToggle(e: Event) {
    if ((e.currentTarget as HTMLDetailsElement).open) void loadRelations();
  }

  async function loadRelations() {
    if (relLoaded || relLoading) return;
    relLoading = true;
    relError = null;
    try {
      const [b, m] = await Promise.all([getBlocks(), getMutes()]);
      blocks = b;
      mutes = m;
      relLoaded = true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        void goto('/');
        return;
      }
      relError = $t('common.readFailed');
    } finally {
      relLoading = false;
    }
  }

  async function doUnblock(a: Account) {
    try {
      await unblockAccount(a.id);
      blocks = blocks.filter((x) => x.id !== a.id);
    } catch {
      // 失敗時はそのまま。開き直して押し直せる。
    }
  }

  async function doUnmute(a: Account) {
    try {
      await unmuteAccount(a.id);
      mutes = mutes.filter((x) => x.id !== a.id);
    } catch {
      // 失敗時はそのまま。
    }
  }

  async function save() {
    if (!me || saving) return;
    saving = true;
    error = null;
    saved = false;
    try {
      const updated = await updateCredentials({
        display_name: displayName,
        note,
        locked,
        discoverable,
        indexable,
        fields: fields
          .map((f) => ({ name: f.name.trim(), value: f.value.trim() }))
          .filter((f) => f.name !== ''),
        avatar: avatarFile,
        header: headerFile
      });
      me = updated;
      // Refresh the memoised account too, so the nav avatar updates on the
      // next read instead of lingering on the pre-save image.
      setCurrentAccount(updated);
      avatarFile = null;
      headerFile = null;
      saved = true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        void goto('/');
        return;
      }
      error = $t('settings.saveFailed');
    } finally {
      saving = false;
    }
  }
</script>

<header class="timeline page-head">
  <h1>{$t('settings.title')}</h1>
</header>

<section class="timeline" style="margin-block: var(--space-4);">
  <p class="muted" style="margin-bottom: var(--space-2);">{$t('settings.language')}</p>
  <LangSwitch />
</section>

{#if loading}
  <p class="loading">{$t('common.loading')}</p>
{:else if me}
  <form
    class="settings-form"
    onsubmit={(e) => {
      e.preventDefault();
      void save();
    }}
  >
    <p class="muted">@{me.acct}</p>

    <label class="stack-tight">
      <span>{$t('settings.displayName')}</span>
      <input type="text" bind:value={displayName} maxlength="30" />
    </label>

    <label class="stack-tight">
      <span>{$t('settings.bio')}</span>
      <textarea bind:value={note} rows="4" maxlength="500"></textarea>
    </label>

    <div class="stack-tight">
      <span>{$t('settings.fields')}</span>
      <p class="muted" style="font-size: var(--text-sm);">{$t('settings.fieldsHint')}</p>
      {#each fields as f, i (i)}
        <div class="field-row">
          <input
            type="text"
            bind:value={f.name}
            maxlength="255"
            placeholder={$t('settings.fieldName')}
            aria-label={$t('settings.fieldName')}
          />
          <input
            type="text"
            bind:value={f.value}
            maxlength="512"
            placeholder={$t('settings.fieldValue')}
            aria-label={$t('settings.fieldValue')}
          />
          <button type="button" class="chip" onclick={() => removeField(i)}>{$t('settings.fieldRemove')}</button>
        </div>
      {/each}
      {#if fields.length < MAX_FIELDS}
        <button type="button" class="chip" onclick={addField}>{$t('settings.fieldAdd')}</button>
      {/if}
    </div>

    <label class="stack-tight">
      <span>{avatarPreview ? $t('settings.avatarNew') : $t('settings.avatarNow')}</span>
      {#if avatarPreview}
        <img class="avatar avatar-lg" src={avatarPreview} alt="" />
      {:else}
        <Avatar class="avatar avatar-lg" src={me.avatar} name={me.display_name || me.username} />
      {/if}
      <input type="file" accept="image/*" onchange={onAvatar} />
    </label>

    <label class="stack-tight">
      <span>{headerPreview ? $t('settings.headerNew') : $t('settings.headerNow')}</span>
      {#if headerPreview}
        <img class="profile-header" src={headerPreview} alt="" />
      {:else if me.header}
        <img class="profile-header" src={me.header} alt="" />
      {/if}
      <input type="file" accept="image/*" onchange={onHeader} />
    </label>

    <label class="stack-tight">
      <input type="checkbox" bind:checked={locked} />
      <span>{$t('settings.locked')}</span>
    </label>

    <label class="stack-tight">
      <input type="checkbox" bind:checked={discoverable} />
      <span>{$t('settings.discoverable')}</span>
    </label>

    <label class="stack-tight">
      <input type="checkbox" bind:checked={indexable} />
      <span>{$t('settings.indexable')}</span>
    </label>
    <p class="muted">{$t('settings.searchConsentHint')}</p>

    <div style="display: flex; gap: var(--space-3); align-items: center;">
      <button type="submit" class="btn px-6 py-2" disabled={saving}>
        {saving ? $t('settings.saving') : $t('settings.save')}
      </button>
      {#if saved}
        <span class="muted">{$t('settings.saved')}</span>
      {/if}
    </div>

    {#if error}
      <p class="error">{error}</p>
    {/if}
  </form>

  <p class="prose-small" style="margin-top: var(--space-4);">
    <a class="chip" href="/settings/password">{$t('settings.changePassword')}</a>
    <a class="chip" href="/settings/security">{$t('settings.security')}</a>
    <a class="chip" href="/settings/migration">{$t('settings.migration')}</a>
    <a class="chip" href="/requests">{$t('requests.title')}</a>
    <a class="chip" href="/settings/cleanup">{$t('settings.cleanup')}</a>
  </p>

  <PushToggle />

  <details class="rel-manage timeline" style="margin-top: var(--space-5);" ontoggle={onRelToggle}>
    <summary style="font-size: var(--text-base); cursor: pointer;">{$t('settings.blockMute')}</summary>

    {#if relLoading}
      <p class="loading">{$t('common.loading')}</p>
    {:else if relError}
      <p class="error">{relError}</p>
    {:else if relLoaded}
      <h2 style="font-size: var(--text-sm); margin-top: var(--space-3);">{$t('settings.blocking')}</h2>
      {#if blocks.length === 0}
        <p class="prose-small">{$t('settings.noneHere')}</p>
      {:else}
        {#each blocks as a (a.id)}
          <AccountActionRow account={a} actionLabel={$t('settings.release')} onaction={doUnblock} />
        {/each}
      {/if}

      <h2 style="font-size: var(--text-sm); margin-top: var(--space-4);">{$t('settings.muting')}</h2>
      {#if mutes.length === 0}
        <p class="prose-small">{$t('settings.noneHere')}</p>
      {:else}
        {#each mutes as a (a.id)}
          <AccountActionRow account={a} actionLabel={$t('settings.release')} onaction={doUnmute} />
        {/each}
      {/if}
    {/if}
  </details>

  {#if me.role?.name === 'admin' && adminToken}
    <!-- /admin は別ドア(bearer 貼り付けログイン)。SPA が持っている
         トークンをそのまま POST して、貼り直しなしで入れるようにする。
         通常のリンクではなく form なのは、/admin/login が token を
         body で受けて session cookie を立てて 302 する作りだから。 -->
    <section class="admin-entry timeline" style="margin-top: var(--space-5);">
      <h2 style="font-size: var(--text-base);">{$t('settings.admin')}</h2>
      <p class="muted">{$t('settings.adminDesc')}</p>
      <form method="post" action="/admin/login">
        <input type="hidden" name="token" value={adminToken} />
        <button type="submit" class="chip">{$t('settings.adminEnter')}</button>
      </form>
    </section>
  {/if}
{/if}

{#if cropTarget && cropSource}
  {#if cropTarget === 'avatar'}
    <ImageCrop
      file={cropSource}
      aspect={1}
      outWidth={512}
      outHeight={512}
      outMime="image/png"
      title={$t('crop.avatarTitle')}
      ondone={onCropDone}
      oncancel={onCropCancel}
    />
  {:else}
    <ImageCrop
      file={cropSource}
      aspect={3}
      outWidth={1500}
      outHeight={500}
      outMime="image/jpeg"
      title={$t('crop.headerTitle')}
      ondone={onCropDone}
      oncancel={onCropCancel}
    />
  {/if}
{/if}

<footer class="muted timeline" style="margin-top: var(--space-6); font-size: var(--text-sm);">
  {$t('settings.emojiCreditPre')}<a href="https://github.com/jdecked/twemoji" target="_blank" rel="noopener noreferrer">Twemoji</a>{$t('settings.emojiCreditParenOpen')}<a
    href="https://creativecommons.org/licenses/by/4.0/"
    target="_blank"
    rel="noopener noreferrer">CC-BY 4.0</a
  >{$t('settings.emojiCreditParenClose')}
</footer>

<style>
  /* プロフィールのひとこと欄の編集行。名前と値を横に並べ、狭い幅では
     縦に折り返す。値の入力を広めに。 */
  .field-row {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    align-items: center;
  }
  .field-row input {
    flex: 1 1 8rem;
    min-width: 0;
  }
</style>
