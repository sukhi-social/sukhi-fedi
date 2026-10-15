<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import {
    getList,
    updateList,
    fetchListTimeline,
    getListAccounts,
    getRelationships,
    addToList,
    removeFromList,
    lookupAccount,
    type List,
    type ListAttrs,
    type HomeReplies,
    type Status,
    type Account,
    type Relationship
  } from '#lib/api.js';
  import { isLoggedIn, clearToken } from '#lib/auth.js';
  import { createPager } from '#lib/pager.svelte.js';
  import StatusCard from '#lib/components/Status.svelte';
  import TimelineFilter from '#lib/components/TimelineFilter.svelte';
  import AccountActionRow from '#lib/components/AccountActionRow.svelte';
  import { t } from '#lib/i18n.js';
  import { refreshCircles } from '#lib/circles.js';

  let id = $derived(page.params.id ?? '');

  let list = $state<List | null>(null);
  // タイムライン部分の先読みページャ。closure は今の id / フィルタを見る。
  const pager = createPager<Status>((maxId) =>
    fetchListTimeline(id, { maxId, onlyMedia, hideSensitive })
  );
  let loading = $state(false);
  let initial = $state(true);
  let error = $state<string | null>(null);

  // 表示フィルター（タイムラインと同じ。リストはブーストを混ぜないので RT 隠しは無し）。
  let onlyMedia = $state(false);
  let hideSensitive = $state(false);

  // ホームに出す条件のうち、キーワード欄だけテキスト。list が読めたら同期する。
  let keyword = $state('');

  // メンバー（<details> を開いたとき一度だけ読む）。
  let members = $state<Account[]>([]);
  let membersLoaded = $state(false);
  // メンバーごとの relationship（フォロー状態）。取れなくても表示は進める。
  let rels = $state<Record<string, Relationship>>({});

  // 未フォローのメンバーが居たら「フォローすると流れる」ヒントを一度出す。
  let hasUnfollowed = $derived(
    members.some((m) => {
      const r = rels[m.id];
      return r && !r.following && !r.requested;
    })
  );
  let addAcct = $state('');
  let addPending = $state(false);
  let addError = $state<string | null>(null);

  onMount(() => {
    if (!isLoggedIn()) {
      goto('/');
      return;
    }
    void load();
  });

  async function load() {
    loading = true;
    error = null;
    try {
      list = await getList(id);
      keyword = list.filter_keyword;
      await pager.reset();
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      if (msg === 'unauthorized') {
        clearToken();
        goto('/');
        return;
      }
      error = msg === 'not_found' ? $t('listDetail.notFound') : $t('common.deliverFailed');
    } finally {
      loading = false;
      initial = false;
    }
  }

  async function loadMore() {
    if (loading) return;
    loading = true;
    try {
      await pager.more();
    } catch {
      // 続きが取れなかったら静かに止める。
    } finally {
      loading = false;
    }
  }

  function onMembersToggle(e: Event) {
    if ((e.currentTarget as HTMLDetailsElement).open && !membersLoaded) void loadMembers();
  }

  async function loadMembers() {
    try {
      members = await getListAccounts(id);
      await loadRels(members.map((m) => m.id));
      membersLoaded = true;
    } catch {
      // 静かに止める。開き直せばまた試す。
    }
  }

  // メンバーの relationship をまとめて引いて rels に重ねる。フォロー状態が
  // 取れなくても（失敗しても）名簿としての表示は止めない。
  async function loadRels(ids: string[]) {
    if (ids.length === 0) return;
    try {
      const rs = await getRelationships(ids);
      const next = { ...rels };
      for (const r of rs) next[r.id] = r;
      rels = next;
    } catch {
      // フォロー状態が無くても、サークルは成立する。
    }
  }

  // FollowButton が返した最新の relationship を反映（ヒントの出し分けに効く）。
  function onFollowChange(r: Relationship) {
    rels = { ...rels, [r.id]: r };
  }

  async function addMember() {
    const acct = addAcct.trim().replace(/^@/, '');
    if (!acct || addPending) return;
    addPending = true;
    addError = null;
    try {
      const a = await lookupAccount(acct);
      await addToList(id, [a.id]);
      if (!members.some((m) => m.id === a.id)) members = [...members, a];
      await loadRels([a.id]);
      void refreshCircles();
      addAcct = '';
    } catch (e) {
      const msg = e instanceof Error ? e.message : '';
      addError = msg === 'not_found' ? $t('listDetail.notFoundPerson') : $t('listDetail.addFailed');
    } finally {
      addPending = false;
    }
  }

  async function removeMember(a: Account) {
    try {
      await removeFromList(id, [a.id]);
      members = members.filter((m) => m.id !== a.id);
      void refreshCircles();
    } catch {
      // 失敗時はそのまま。
    }
  }

  // フィルターを変えたらタイムラインを読み直す。
  function applyFilters() {
    void load();
  }

  // このリストの「ホームに出す条件」を更新する(リストの永続設定)。exclusive を
  // 変えるとバッジ対象も変わるので circles を読み直す。
  async function patchGate(attrs: ListAttrs) {
    try {
      list = await updateList(id, attrs);
      void refreshCircles();
    } catch {
      // 失敗時はそのまま(UI は list の値に描き戻る)。
    }
  }
</script>

<p class="back-row timeline"><a class="back-link" href="/lists">← {$t('listDetail.listIndex')}</a></p>
<header class="timeline page-head">
  <h1>{list?.title ?? $t('listDetail.fallbackTitle')}</h1>
</header>

{#if error}
  <p class="error timeline">{error}</p>
  <p class="timeline"><a class="chip" href="/lists">{$t('listDetail.toListIndex')}</a></p>
{:else}
  {#if list}
    <details class="timeline" style="margin-bottom: var(--space-4);">
      <summary style="cursor: pointer;">{$t('listDetail.homeGateTitle')}</summary>
      <p class="prose-small">{$t('listDetail.homeGateHint')}</p>

      <!-- 出さない(never): ゲートのいちばん端。選ぶと他の条件は効かない。 -->
      <label style="display: flex; align-items: center; gap: var(--space-2); padding: var(--space-1) 0;">
        <input
          type="checkbox"
          checked={list.exclusive}
          onchange={(e) => patchGate({ exclusive: e.currentTarget.checked })}
        />
        <span>{$t('listDetail.gateNever')}</span>
      </label>

      {#if !list.exclusive}
        <p class="prose-small" style="margin-top: var(--space-2);">{$t('listDetail.gateConditionsHint')}</p>
        <label style="display: flex; align-items: center; gap: var(--space-2); padding: var(--space-1) 0;">
          <input
            type="checkbox"
            checked={list.filter_only_media}
            onchange={(e) => patchGate({ filterOnlyMedia: e.currentTarget.checked })}
          />
          <span>{$t('timeline.onlyMedia')}</span>
        </label>
        <label style="display: flex; align-items: center; gap: var(--space-2); padding: var(--space-1) 0;">
          <input
            type="checkbox"
            checked={list.filter_hide_boosts}
            onchange={(e) => patchGate({ filterHideBoosts: e.currentTarget.checked })}
          />
          <span>{$t('timeline.hideBoosts')}</span>
        </label>
        <label style="display: flex; align-items: center; gap: var(--space-2); padding: var(--space-1) 0;">
          <input
            type="checkbox"
            checked={list.filter_hide_sensitive}
            onchange={(e) => patchGate({ filterHideSensitive: e.currentTarget.checked })}
          />
          <span>{$t('timeline.hideSensitive')}</span>
        </label>

        <label style="display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2); padding: var(--space-1) 0;">
          <span>{$t('listDetail.gateKeyword')}</span>
          <input
            type="text"
            bind:value={keyword}
            placeholder={$t('listDetail.gateKeywordPlaceholder')}
            onchange={() => patchGate({ filterKeyword: keyword.trim() })}
            style="flex: 1; min-width: 8rem;"
          />
        </label>

        <label style="display: flex; align-items: center; gap: var(--space-2); padding: var(--space-1) 0;">
          <span>{$t('listDetail.gateReplies')}</span>
          <select
            value={list.filter_replies}
            onchange={(e) => patchGate({ filterReplies: e.currentTarget.value as HomeReplies })}
          >
            <option value="all">{$t('listDetail.gateRepliesAll')}</option>
            <option value="hide">{$t('listDetail.gateRepliesHide')}</option>
            <option value="to_me">{$t('listDetail.gateRepliesToMe')}</option>
          </select>
        </label>
      {/if}
    </details>
  {/if}

  <details class="timeline" ontoggle={onMembersToggle} style="margin-bottom: var(--space-4);">
    <summary style="cursor: pointer;">{$t('listDetail.members')}</summary>

    <form
      onsubmit={(e) => {
        e.preventDefault();
        void addMember();
      }}
      style="display: flex; gap: var(--space-2); margin: var(--space-3) 0;"
    >
      <input
        type="text"
        bind:value={addAcct}
        placeholder={$t('listDetail.addPlaceholder')}
        style="flex: 1;"
      />
      <button type="submit" class="btn px-6 py-2" disabled={addPending || !addAcct.trim()}>{$t('listDetail.add')}</button>
    </form>

    {#if addError}
      <p class="error">{addError}</p>
    {/if}

    {#if membersLoaded && members.length === 0}
      <p class="prose-small">{$t('listDetail.noMembers')}</p>
    {/if}
    {#if hasUnfollowed}
      <p class="prose-small">{$t('listDetail.followHint')}</p>
    {/if}
    {#each members as a (a.id)}
      <AccountActionRow
        account={a}
        actionLabel={$t('listDetail.removeMember')}
        onaction={removeMember}
        relationship={rels[a.id] ?? null}
        onfollowchange={onFollowChange}
      />
    {/each}
  </details>

  <div class="timeline">
    <TimelineFilter bind:onlyMedia bind:hideSensitive onchange={applyFilters} />
  </div>

  <section class="timeline">
    {#if initial && loading}
      <p class="loading">{$t('common.loading')}</p>
    {:else if pager.items.length === 0 && !loading}
      <p class="prose-small">
        {$t('listDetail.empty')}
      </p>
    {/if}

    {#each pager.items as s (s.id)}
      <StatusCard
        status={s}
        canReply
        ondelete={(d) => pager.items = pager.items.filter((it) => it.id !== d.id)}
      />
    {/each}

    {#if !initial && (loading || pager.revealing)}
      <p class="loading">{$t('common.loading')}</p>
    {/if}

    {#if pager.hasMore && !loading && !pager.revealing}
      <button class="load-more" onclick={loadMore}>{$t('common.loadMore')}</button>
    {/if}
  </section>
{/if}

<style>
  /* 見出しの上に、そっと一行で置く「← もどる先」(パンくず)。.timeline と
     併用して本文と同じ measure 幅にそろえ、左端から始める。見出しとの
     間は .stack の標準 gap(space-4)だと浮くので、隣接見出しだけ tight に
     寄せる(owl より詳細度が高いので勝つ)。 */
  .back-link {
    font-size: var(--text-sm);
    color: var(--color-text-muted);
    text-decoration: none;
  }
  .back-link:hover {
    color: var(--color-text);
    text-decoration: underline;
  }
  .back-row + .page-head {
    margin-top: var(--space-1);
  }
</style>
