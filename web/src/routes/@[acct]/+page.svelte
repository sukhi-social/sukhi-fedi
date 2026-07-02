<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import {
    lookupAccount,
    getAccountStatuses,
    getRelationships,
    verifyCredentials,
    blockAccount,
    unblockAccount,
    muteAccount,
    unmuteAccount,
    setAccountNote,
    type Account,
    type Relationship,
    type Status
  } from '$lib/api';
  import { isLoggedIn, clearToken } from '$lib/auth';
  import { createPager } from '$lib/pager.svelte';
  import { proxyVariants } from '$lib/proxyImage';
  import StatusCard from '$lib/components/Status.svelte';
  import Avatar from '$lib/components/Avatar.svelte';
  import FollowButton from '$lib/components/FollowButton.svelte';
  import AddToListButton from '$lib/components/AddToListButton.svelte';
  import Composer from '$lib/components/Composer.svelte';
  import Twemoji from '$lib/components/Twemoji.svelte';
  import TimelineFilter from '$lib/components/TimelineFilter.svelte';
  import MediaGrid from '$lib/components/MediaGrid.svelte';
  import { phrase } from '$lib/phrase';
  import { renderEmojis } from '$lib/emoji';
  import { t } from '$lib/i18n';

  let account = $state<Account | null>(null);
  let me = $state<Account | null>(null);
  let rel = $state<Relationship | null>(null);
  let pinnedItems = $state<Status[]>([]);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let initial = $state(true);

  // 記事（Article）を持つ人にだけ、プロフィールに「記事」タブを出す。
  // 読み込み時に一度だけ記事を引いて、あればタブを立てる。
  let tab = $state<'posts' | 'articles'>('posts');

  // 投稿タブの表示フィルター。「画像・メディアのみ」を入れると only_media で
  // 読み直し、そのとき「写真」を選ぶとサムネの壁(MediaGrid)に切り替わる。
  // viewMode は描き分けるだけなので読み直さない。
  let onlyMedia = $state(false);
  let viewMode = $state<'list' | 'photo'>('list');

  // 投稿と記事、それぞれの先読みページャ。closure は今の account / onlyMedia
  // を見る(フィルタ変更や別ユーザは reset で入れ替わる)。
  const postsPager = createPager<Status>((maxId) =>
    getAccountStatuses(account!.id, { maxId, onlyMedia })
  );
  const articlesPager = createPager<Status>((maxId) =>
    getAccountStatuses(account!.id, { maxId, articles: true })
  );
  let hasArticles = $derived(articlesPager.items.length > 0);

  let acct = $derived($page.params.acct ?? '');
  let isSelf = $derived(!!account && !!me && me.id === account.id);

  // プロフィール上の投稿にも、その場で返信できるように。返信先の公開範囲は
  // Composer が引き継ぐ。送れたら自分のプロフィールを見ているとき(=自分への
  // 返信は稀)だけ先頭に足す、ということはせず、素直に閉じるだけにする。
  let replyTo = $state<Status | null>(null);
  let quoteOf = $state<Status | null>(null);
  let composerOpen = $state(false);

  function onReply(s: Status) {
    replyTo = s;
    quoteOf = null;
    composerOpen = true;
    if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function onQuote(s: Status) {
    quoteOf = s;
    replyTo = null;
    composerOpen = true;
    if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function onPosted() {
    composerOpen = false;
    replyTo = null;
    quoteOf = null;
  }

  function onCancel() {
    composerOpen = false;
    replyTo = null;
    quoteOf = null;
  }

  // ピン留め欄でピンを外したら、その場で欄から外す。
  function onPinUpdate(s: Status) {
    if (!s.pinned) pinnedItems = pinnedItems.filter((it) => it.id !== s.id);
  }

  // ブロック / ミュート。relationship を握り直して表示に反映する。
  let modPending = $state(false);
  let menuOpen = $state(false);

  // 私的メモ(あなただけに見える呼び名)。本名の隣にそっと置くだけで、
  // 本名を上書きはしない。たたんでおいて、開いたときだけ書ける。
  let noteOpen = $state(false);
  let noteDraft = $state('');
  let notePending = $state(false);

  function openNote() {
    noteDraft = rel?.note ?? '';
    noteOpen = true;
  }

  async function saveNote() {
    if (!account || notePending) return;
    notePending = true;
    try {
      rel = await setAccountNote(account.id, noteDraft.trim());
      noteOpen = false;
    } catch {
      // 失敗は黙って欄を開けたまま戻す。
    } finally {
      notePending = false;
    }
  }

  async function toggleBlock() {
    if (!account || modPending) return;
    modPending = true;
    try {
      rel = rel?.blocking ? await unblockAccount(account.id) : await blockAccount(account.id);
    } catch {
      // 失敗は黙って戻す(rel はそのまま)。
    } finally {
      modPending = false;
      menuOpen = false;
    }
  }

  async function toggleMute() {
    if (!account || modPending) return;
    modPending = true;
    try {
      rel = rel?.muting ? await unmuteAccount(account.id) : await muteAccount(account.id);
    } catch {
      // 同上。
    } finally {
      modPending = false;
      menuOpen = false;
    }
  }

  onMount(() => {
    void load();
  });

  async function load() {
    loading = true;
    error = null;
    try {
      account = await lookupAccount(acct);
      // 自分かどうかを判定するため、ログイン時だけ自分を引く。
      if (isLoggedIn()) {
        try {
          me = await verifyCredentials();
        } catch {
          me = null;
        }
        if (me && me.id !== account.id) {
          const rs = await getRelationships([account.id]);
          rel = rs[0] ?? null;
        }
      }
      const empty = { items: [] as Status[], nextMaxId: null };
      // 投稿・記事・ピン留めを一度に。記事とピンは取れなくてもプロフィール
      // 本体は出す(投稿の失敗だけは下の catch でエラーにする)。
      const [, , pins] = await Promise.all([
        postsPager.reset(),
        articlesPager.reset().catch(() => {}),
        getAccountStatuses(account.id, { pinned: true }).catch(() => empty)
      ]);
      // featured 由来＝定義上ピン留め済み。サーバの viewer flag を待たず
      // フラグを立て、メニューが「外す」を出せるようにする。
      pinnedItems = pins.items.map((s) => ({ ...s, pinned: true }));
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        void goto('/');
        return;
      }
      if (msg === 'not_found') {
        error = $t('common.acctNotFound', { acct });
      } else {
        error = $t('common.deliverFailed');
      }
    } finally {
      loading = false;
      initial = false;
    }
  }

  async function loadMore() {
    if (!account || loading) return;
    loading = true;
    try {
      await postsPager.more();
    } catch {
      // 続きが取れなかったら静かに止める。
    } finally {
      loading = false;
    }
  }

  // フィルター(画像・メディアのみ)を変えたら、投稿の一覧だけ頭から読み直す。
  async function applyFilters() {
    if (!account || loading) return;
    loading = true;
    try {
      await postsPager.reset();
    } catch {
      // 取れなければ静かに、いまの一覧のまま。
    } finally {
      loading = false;
    }
  }

  async function loadMoreArticles() {
    if (!account || loading) return;
    loading = true;
    try {
      await articlesPager.more();
    } catch {
      // 同上、静かに止める。
    } finally {
      loading = false;
    }
  }
</script>

{#if error}
  <p class="error">{error}</p>
  <p><a class="chip" href="/timeline">{$t('common.backToTimeline')}</a></p>
{:else if initial && loading}
  <p class="loading">{$t('common.loading')}</p>
{:else if account}
  <header class="profile-head">
    {#if account.header}
      {@const v = proxyVariants(account.header)}
      <picture>
        {#if v}
          <source srcset={v.avif} type="image/avif" />
          <source srcset={v.webp} type="image/webp" />
        {/if}
        <img class="profile-header" src={account.header} alt="" loading="lazy" />
      </picture>
    {/if}
    <div class="profile-id">
      <Avatar class="avatar avatar-lg" src={account.avatar} name={account.display_name || account.username} />
      <div class="stack-tight" style="flex: 1;">
        <p class="display-name" style="font-size: var(--text-lg);">
          {@html renderEmojis(phrase(account.display_name || account.username), account.emojis)}
        </p>
        <p class="muted">@{account.acct}</p>
        {#if rel}
          <!-- 本名の下に、あなただけに見える呼び名をそっと。本名は上に
               残したまま、上書きはしない。 -->
          {#if noteOpen}
            <div class="account-note-edit">
              <label class="account-note-label" for="account-note-input">{$t('profile.noteLabel')}</label>
              <textarea
                id="account-note-input"
                class="account-note-input"
                rows="2"
                bind:value={noteDraft}
                placeholder={$t('profile.notePlaceholder')}
              ></textarea>
              <div class="account-note-actions">
                <button type="button" class="chip" onclick={saveNote} disabled={notePending}>
                  {$t('profile.noteSave')}
                </button>
                <button type="button" class="chip" onclick={() => (noteOpen = false)} disabled={notePending}>
                  {$t('profile.noteCancel')}
                </button>
              </div>
            </div>
          {:else if rel.note}
            <button type="button" class="account-note-line" onclick={openNote}>
              <span class="account-note-tag">{$t('profile.noteLabel')}</span> {rel.note}
            </button>
          {:else}
            <button type="button" class="account-note-add" onclick={openNote}>
              {$t('profile.noteAdd')}
            </button>
          {/if}
        {/if}
      </div>
      {#if isSelf}
        <a class="chip" href="/settings">{$t('profile.edit')}</a>
      {:else}
        <div class="profile-actions">
          <FollowButton accountId={account.id} relationship={rel} onchange={(r) => (rel = r)} />
        {#if rel}
          <AddToListButton accountId={account.id} />
        {/if}
        {#if rel}
          <div class="mod-menu">
            <button
              type="button"
              class="chip"
              aria-haspopup="menu"
              aria-expanded={menuOpen}
              onclick={() => (menuOpen = !menuOpen)}>…</button
            >
            {#if menuOpen}
              <div class="mod-menu-pop" role="menu">
                <button type="button" role="menuitem" onclick={toggleMute} disabled={modPending}>
                  {rel.muting ? $t('profile.unmute') : $t('profile.mute')}
                </button>
                <button
                  type="button"
                  role="menuitem"
                  class="danger"
                  onclick={toggleBlock}
                  disabled={modPending}
                >
                  {rel.blocking ? $t('profile.unblock') : $t('profile.block')}
                </button>
              </div>
            {/if}
          </div>
        {/if}
        </div>
      {/if}
    </div>

    {#if account.note}
      <div class="profile-note">{@html renderEmojis(account.note, account.emojis)}</div>
    {/if}

    {#if account.fields && account.fields.length > 0}
      <!-- プロフィールのひとこと欄。本人が自分で選んで置いた、静かな
           key/value の行。連合するので、どの画面でも同じものが見える。
           verified_at は使わない（こちらでは rel="me" 検証をしないので、
           「確認済み」を装わない）。 -->
      <dl class="profile-fields">
        {#each account.fields as f (f.name)}
          <div class="profile-field">
            <dt>{@html renderEmojis(f.name, account.emojis)}</dt>
            <dd>{@html renderEmojis(f.value, account.emojis)}</dd>
          </div>
        {/each}
      </dl>
    {/if}

    <p class="profile-counts">
      <a href={`/@${account.acct}/following`}>
        <strong>{account.following_count ?? 0}</strong> {$t('profile.followingSuffix')}
      </a>
      <a href={`/@${account.acct}/followers`}>
        <strong>{account.followers_count ?? 0}</strong> {$t('profile.followersSuffix')}
      </a>
      <span><strong>{account.statuses_count ?? 0}</strong> {$t('profile.postsSuffix')}</span>
    </p>
  </header>

  {#if composerOpen}
    <Composer {replyTo} {quoteOf} prefillMention={!!replyTo} onposted={onPosted} oncancel={onCancel} />
  {/if}

  {#if hasArticles}
    <!-- 記事を持つ人だけ、投稿と記事を分けて見られるように。 -->
    <nav class="profile-tabs measure" aria-label={$t('profile.tabsLabel')}>
      <button class="tab" class:active={tab === 'posts'} onclick={() => (tab = 'posts')}>
        {$t('profile.tabPosts')}
      </button>
      <button class="tab" class:active={tab === 'articles'} onclick={() => (tab = 'articles')}>
        {$t('profile.tabArticles')}
      </button>
    </nav>
  {/if}

  {#if tab === 'articles'}
    <section class="timeline">
      {#each articlesPager.items as s (s.id)}
        <StatusCard
          status={s}
          canReply
          onreply={onReply}
          onquote={onQuote}
          ondelete={(d) =>
            (articlesPager.items = articlesPager.items.filter((it) => it.id !== d.id))}
        />
      {/each}

      {#if articlesPager.hasMore && !loading && !articlesPager.revealing}
        <button class="load-more" onclick={loadMoreArticles}>{$t('common.loadMore')}</button>
      {/if}
    </section>
  {:else}
    <div class="measure">
      <TimelineFilter bind:onlyMedia bind:viewMode showViewMode onchange={applyFilters} />
    </div>

    {#if onlyMedia && viewMode === 'photo'}
      <!-- 写真モード: メディアを持つ投稿をサムネの壁で。ピン留めは一覧の作法
           なのでここでは出さない。 -->
      <section class="timeline">
        {#if postsPager.items.length === 0 && !loading}
          <p class="prose-small">{$t('profile.empty')}</p>
        {/if}

        <MediaGrid items={postsPager.items} />

        {#if !initial && (loading || postsPager.revealing)}
          <p class="loading">{$t('common.loading')}</p>
        {/if}

        {#if postsPager.hasMore && !loading && !postsPager.revealing}
          <button class="load-more" onclick={loadMore}>{$t('common.loadMore')}</button>
        {/if}
      </section>
    {:else}
      {#if pinnedItems.length > 0}
        <section class="timeline pinned">
          <p class="pinned-label"><Twemoji emoji="📌" /> {$t('profile.pinned')}</p>
          {#each pinnedItems as s (s.id)}
            <StatusCard
              status={s}
              canReply
              onreply={onReply}
              onquote={onQuote}
              onupdate={onPinUpdate}
              ondelete={(d) => (pinnedItems = pinnedItems.filter((it) => it.id !== d.id))}
            />
          {/each}
        </section>
      {/if}

      <section class="timeline">
        {#if postsPager.items.length === 0 && !loading}
          <p class="prose-small">{$t('profile.empty')}</p>
        {/if}

        {#each postsPager.items as s (s.id)}
          <StatusCard
            status={s}
            canReply
            onreply={onReply}
            onquote={onQuote}
            ondelete={(d) => (postsPager.items = postsPager.items.filter((it) => it.id !== d.id))}
          />
        {/each}

        {#if !initial && (loading || postsPager.revealing)}
          <p class="loading">{$t('common.loading')}</p>
        {/if}

        {#if postsPager.hasMore && !loading && !postsPager.revealing}
          <button class="load-more" onclick={loadMore}>{$t('common.loadMore')}</button>
        {/if}
      </section>
    {/if}
  {/if}
{/if}

<style>
  /* フォロー/リスト追加/… を一塊にして、狭い幅では折り返す（モバイルで
     横に溢れないように）。avatar + 名前の右に寄せる。 */
  .profile-actions {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-wrap: wrap;
    justify-content: flex-end;
    margin-left: auto;
  }
  .mod-menu {
    position: relative;
    display: inline-block;
  }
  .mod-menu-pop {
    position: absolute;
    right: 0;
    top: calc(100% + 0.25rem);
    z-index: 10;
    display: flex;
    flex-direction: column;
    min-width: 10rem;
    padding: 0.25rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
  }
  .mod-menu-pop button {
    text-align: left;
    padding: 0.5rem 0.625rem;
    background: none;
    border: none;
    border-radius: var(--radius-sm);
    cursor: pointer;
  }
  .mod-menu-pop button:hover:not(:disabled) {
    background: var(--fill-hover);
  }
  .mod-menu-pop button.danger {
    color: var(--color-danger);
  }
  .pinned-label {
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }

  /* プロフィールのひとこと欄。落ち着いた区切りの行。各行は名前（淡く）と
     値を横に並べ、狭い幅では縦に折り返す。動かない、飾らない。 */
  .profile-fields {
    margin: 0;
    border-top: 1px solid var(--color-border);
  }
  .profile-field {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-1) var(--space-3);
    padding: var(--space-2) 0;
    border-bottom: 1px solid var(--color-border);
    font-size: var(--text-sm);
  }
  .profile-field dt {
    color: var(--color-text-muted);
    flex: 0 0 auto;
    min-width: 6rem;
  }
  .profile-field dd {
    margin: 0;
    flex: 1 1 12rem;
    min-width: 0;
    word-break: break-word;
  }

  /* 私的メモ。本名の下に、ひかえめに。連合しない、あなただけの呼び名。
     クリックで開くだけで、視線をうばわない。 */
  .account-note-line,
  .account-note-add {
    font-size: var(--text-sm);
    color: var(--color-text-muted);
    text-align: left;
    background: none;
    border: none;
    padding: 0;
    cursor: pointer;
  }
  .account-note-tag {
    color: var(--color-text-muted);
    opacity: 0.7;
  }
  .account-note-edit {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }
  .account-note-label {
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }
  .account-note-input {
    width: 100%;
    font-size: var(--text-sm);
  }
  .account-note-actions {
    display: flex;
    gap: var(--space-2);
  }

  /* 投稿 / 記事 の切り替え。控えめに、下線で今いる場所だけ示す。 */
  .profile-tabs {
    display: flex;
    gap: var(--space-1);
    border-bottom: 1px solid var(--color-border);
  }
  .profile-tabs .tab {
    padding: 0.5rem 0.9rem;
    background: none;
    border: none;
    border-bottom: 2px solid transparent;
    margin-bottom: -1px;
    color: var(--color-text-muted);
    cursor: pointer;
  }
  .profile-tabs .tab.active {
    color: var(--color-text);
    border-bottom-color: var(--color-text);
  }
</style>
