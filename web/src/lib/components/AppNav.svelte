<script lang="ts">
  // ログイン後の全ページにかかる共通ナビ。
  //
  //   上の帯(.nav-top)  — デスクトップでは「流れ」も「棚」も全部。
  //     スマホでは流れを下へ譲り、棚(ライブラリ・アバター)だけが残る。
  //   下の帯(.nav-bottom) — スマホだけ。親指の届くところに「流れ」
  //     (ホーム・さがす・書く・通知・メッセージ)。fixed で消えない。
  //
  // 棚はふたつのドロップダウンに畳んだ:
  //   📁 ライブラリ — ブックマーク / お気に入り / リスト(自分の保存)
  //   👤 アバター   — プロフィール / 設定 / ログアウト(自分のこと)
  // 「いま来るもの」は親指の下、「ときどき訪ねるもの」は畳んで上に。
  //
  // ログイン状態は localStorage なので mount 時とページ遷移のたびに
  // 見直す。下の帯が出ている間は <body> に has-bottom-nav を付けて、
  // 本文の下に帯のぶんの余白を空ける。アバターは verify_credentials を
  // 共有メモ(currentAccount)から一度だけ取る。
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { afterNavigate } from '$app/navigation';
  import {
    isLoggedIn,
    signOutServer,
    loadOtherAccounts,
    loadToken,
    switchAccount,
    removeAccount,
    startAddAccount,
    type StoredAccount
  } from '#lib/auth.js';
  import Avatar from './Avatar.svelte';
  import AccountPicker from './AccountPicker.svelte';
  import { hasAdmin, loadAdminChoices, type AdminChoice } from '#lib/adminPicker.js';
  import { currentAccount, type Account } from '#lib/api.js';
  import {
    directUnseen,
    ambientUnseen,
    refreshUnseen,
    startStream,
    stopStream
  } from '#lib/notify.js';
  import NavIcon, { type IconName } from '#lib/components/NavIcon.svelte';
  import NavMenu from '#lib/components/NavMenu.svelte';
  import NotifGlyph from '#lib/components/NotifGlyph.svelte';
  import { t, type TranslationKey } from '#lib/i18n.js';

  type FlowItem = {
    key: TranslationKey;
    icon: IconName;
    href: string;
  };

  const home: FlowItem = { href: '/timeline', key: 'nav.home', icon: 'home' };
  const notif: FlowItem = { href: '/notifications', key: 'nav.notifications', icon: 'bell' };
  const messages: FlowItem = { href: '/messages', key: 'nav.messages', icon: 'mail' };
  const search: FlowItem = { href: '/search', key: 'nav.search', icon: 'search' };
  // 「書く」は自分の面を持つようになった。前はここだけ action で、
  // /timeline へ移ってから store で合図し、流れの上に composer を開いて
  // いた ── いまはただのリンク。
  const compose: FlowItem = { href: '/compose', key: 'nav.compose', icon: 'compose' };

  // 上の帯の流れ(書くを先頭に)。下の帯は親指の並び(書くを中央に)。
  const flowTop: FlowItem[] = [compose, home, notif, messages, search];
  const flowBottom: FlowItem[] = [home, search, compose, notif, messages];

  let loggedIn = $state(false);
  let me = $state<Account | null>(null);
  // 他に一度ログインしたことのあるアカウント(いま見ている me は含まない)。
  let otherAccounts = $state<StoredAccount[]>([]);
  // 管理画面の入口。サインイン中の誰かが admin のときだけ、アカウントの
  // メニューに「管理」を出す。候補(adminChoices)は、顔ぶれが変わった
  // ときだけ組み直す。
  let adminChoices = $state<AdminChoice[]>([]);
  let adminKey = '';
  let adminPickerOpen = $state(false);
  let accountMenuOpen = $state(false);

  // 会話の面は「入った先」。ここは行き先を選ぶ場所ではなく、もう誰かと
  // 話している場所なので、流れの帯は畳んで、左上を戻る口にする ──
  // スマホのアプリが、話の画面でタブを消して ← を出すのと同じ約束。
  // (畳んだぶんの高さは、そのまま会話に返る。)
  let inThread = $derived((/^\/messages\/[^/]+\/?$/).test(page.url.pathname));
  let showBottomNav = $derived(loggedIn && !inThread);
  let showAdminEntry = $derived(loggedIn && hasAdmin(adminChoices));

  function sync() {
    loggedIn = isLoggedIn();
    if (loggedIn) {
      void refreshUnseen();
      void currentAccount().then((a) => {
        me = a;
        void refreshAdmin(a);
      });
      otherAccounts = loadOtherAccounts();
      startStream();
    } else {
      me = null;
      otherAccounts = [];
      adminChoices = [];
      adminKey = '';
      stopStream();
    }
  }

  // 他のアカウントの role は token から引き直す必要があるので、顔ぶれが
  // 変わったときだけ解決する ── 毎回の遷移では呼ばない。
  async function refreshAdmin(account: Account | null) {
    const token = loadToken()?.access_token;
    if (!account || !token) {
      adminChoices = [];
      adminKey = '';
      return;
    }
    const key = `${account.acct}|${otherAccounts.map((a) => a.acct).sort().join(',')}`;
    if (key === adminKey) return;
    adminKey = key;
    adminChoices = await loadAdminChoices(account, token);
  }

  function openAdminPicker() {
    accountMenuOpen = false;
    adminPickerOpen = true;
  }

  // 下の帯のぶんの余白と、会話の面の下余白は、もう JS で <body> に旗を立てない。
  // 全体の CSS(src/styles/app.css)が、帯(.nav-bottom)と戻る印(.app-nav-back)が
  // DOM に居るかを :has() で見て決める。
  onMount(() => {
    sync();
    return () => {
      stopStream();
    };
  });

  afterNavigate(({ shallow, type }) => {
    if (shallow && type === 'goto') return;

    sync();
  });

  // 読み上げと hover には、かたちでなく言葉で正直に。
  const notifHint = $derived.by(() => {
    const parts: string[] = [];
    if ($directUnseen > 0) parts.push($t('nav.notifDirect', { n: $directUnseen }));
    if ($ambientUnseen > 0) parts.push($t('nav.notifAmbient'));
    return parts.length > 0 ? parts.join(' / ') : null;
  });

  // 「ログアウト」は、いま見ているアカウントだけを外す ── 他にも
  // サインインしているアカウントがあれば、そちらへ格上げされて続く
  // (removeAccount の約束)。誰も残らなければ、これまで通り本当の
  // ログアウト。ページ内の状態(タイムライン等)はアカウントに紐づく
  // ので、切り替え後は必ずフルリロードで作り直す。
  async function signOut() {
    if (me) {
      await removeAccount(me.acct);
    } else {
      await signOutServer();
    }
    window.location.assign(isLoggedIn() ? '/timeline' : '/');
  }

  async function switchTo(acct: string) {
    await switchAccount(acct);
    window.location.assign('/timeline');
  }
</script>

<!-- 流れの一項目。どれもただのリンク(「書く」も /compose を持つように
     なったので、ここに分岐は無い)。通知だけ未見の指標を抱える。 -->
{#snippet flowLink(item: FlowItem)}
  {@const href = item.href}
  {@const isNotif = href === '/notifications'}
  <a
    class="nav-link nav-flow"
    href={href}
    aria-current={page.url.pathname === href ? 'page' : undefined}
    aria-label={isNotif && notifHint ? `${$t(item.key)} — ${notifHint}` : undefined}
    title={isNotif ? notifHint ?? undefined : undefined}
  >
    <NavIcon name={item.icon} />
    <span class="nav-text">
      <span class="nav-label">{$t(item.key)}</span>
      {#if isNotif}
        {#if $directUnseen > 0}
          <span class="notif-count">{$directUnseen}</span>
        {/if}

        {#if $ambientUnseen > 0}
          <NotifGlyph count={$ambientUnseen} />
        {/if}
      {/if}
    </span>
  </a>
{/snippet}

<!-- ドロップダウンの中の一行(行き先リンク)。 -->
{#snippet menuLink(href: string, key: TranslationKey, icon: IconName)}
  <a
    class="nav-menu-item"
    role="menuitem"
    href={href}
    aria-current={page.url.pathname === href ? 'page' : undefined}
  >
    <NavIcon name={icon} />
    <span>{$t(key)}</span>
  </a>
{/snippet}

{#if loggedIn}
  <header class="app-nav">
    <div class="wrap app-nav-row">
      {#if inThread}
        <a class="app-nav-back" href="/messages">
          <NavIcon name="back" />
          <span>{$t('messages.back')}</span>
        </a>
      {:else}
        <a class="app-nav-name" href="/timeline">
          <img class="app-nav-mark" src="/favicon.png" alt="" width="64" height="64" />
          sukhi-fedi
        </a>
      {/if}
      <nav class="nav-top" aria-label={$t('nav.label')}>
        {#each flowTop as item (item.key)}{@render flowLink(item)}{/each}

        <NavMenu ariaLabel={$t('nav.library')}>
          {#snippet trigger()}
            <NavIcon name="library" />
            <span class="nav-label">{$t('nav.library')}</span>
          {/snippet}
          {#snippet children()}
            {@render menuLink('/bookmarks', 'nav.bookmarks', 'bookmark')}
            {@render menuLink('/favourites', 'nav.favourites', 'star')}
            {@render menuLink('/lists', 'nav.lists', 'list')}
          {/snippet}
        </NavMenu>

        <NavMenu
          bind:open={accountMenuOpen}
          ariaLabel={$t('nav.account')}
          triggerClass="nav-avatar-trigger"
        >
          {#snippet trigger()}
            {#if me}
              <Avatar class="nav-avatar" src={me.avatar} name={me.display_name || me.username} />
            {:else}
              <NavIcon name="user" />
            {/if}
          {/snippet}
          {#snippet children()}
            {#if me}{@render menuLink(`/@${me.acct}`, 'nav.profile', 'user')}{/if}
            {#if otherAccounts.length > 0}
              <div class="nav-menu-sep" role="separator"></div>
              {#each otherAccounts as other (other.acct)}
                <button
                  type="button"
                  class="nav-menu-item"
                  role="menuitem"
                  onclick={() => void switchTo(other.acct)}
                >
                  <NavIcon name="user" />
                  <span>@{other.acct}</span>
                </button>
              {/each}
            {/if}
            <button type="button" class="nav-menu-item" role="menuitem" onclick={startAddAccount}>
              <NavIcon name="user" />
              <span>{$t('nav.addAccount')}</span>
            </button>
            <div class="nav-menu-sep" role="separator"></div>
            {#if showAdminEntry}
              <button type="button" class="nav-menu-item" role="menuitem" onclick={openAdminPicker}>
                <NavIcon name="gear" />
                <span>{$t('nav.admin')}</span>
              </button>
            {/if}
            {@render menuLink('/settings', 'nav.settings', 'gear')}
            <button type="button" class="nav-menu-item" role="menuitem" onclick={signOut}>
              <NavIcon name="logout" />
              <span>{$t('nav.logout')}</span>
            </button>
          {/snippet}
        </NavMenu>
      </nav>
    </div>
  </header>

  {#if showBottomNav}
    <nav class="nav-bottom" aria-label={$t('nav.bottomLabel')}>
      {#each flowBottom as item (item.key)}{@render flowLink(item)}{/each}
    </nav>
  {/if}
{/if}

{#if adminPickerOpen}
  <AccountPicker
    title={$t('adminPicker.title')}
    hint={$t('adminPicker.hint')}
    badge={$t('adminPicker.badge')}
    cancelLabel={$t('adminPicker.cancel')}
    action="/admin/login"
    accounts={adminChoices}
    onclose={() => adminPickerOpen = false}
  />
{/if}

<style>
  /* ── 共通ヘッダー ─────────────────────────────────────────────────
     ログイン後の全ページにかかる屋根(AppNav.svelte)。wordmark を左に、
     行き先の nav-link を右に。罫線は画面の端まで通し、中身は .wrap 幅に
     そろえる。広い画面ではここに「流れ」も「棚」も全部出る。狭い画面
     では「流れ」を下の帯(.nav-bottom)に移し、ここには「棚」だけが
     アイコンで残る。 */
  .app-nav {
    /* 屋根を画面上端に貼り付ける。スクロールしても流れの行き先が消えない
       ので、デスクトップで「上まで戻らないと移動できない」がなくなる。
       本文がこの下を流れるので不透明な地色を敷き、境界の罫線で「貼り付い
       ている」ことが分かるようにする。 */
    position: sticky;
    inset-block-start: 0;
    z-index: var(--layer-top-nav);
    background: var(--color-bg);
    border-block-end: 1px solid var(--color-border);
  }

  .app-nav-row {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    justify-content: space-between;
    gap: var(--space-2) var(--space-4);
    padding-block: var(--space-3);
  }

  /* 指の画面では、中の操作がもう --tap-min の高さを持つ。そこへ上下 12px を
     足すと 72px になり、貼り付いた屋根が画面の 1/11 を占める。上下 4px なら
     Android 56dp / 同じ印の 44 + 8 = 52px に収まる(docs/UX_CONTRACT.md)。 */
  @media (pointer: coarse) {
    .app-nav-row {
      padding-block: var(--space-1);
    }
  }

  .app-nav-name {
    font-weight: 700;
    text-decoration: none;
  }

  /* 名前の左の印(手書きの「好」)。行は baseline 揃えなので flex にせず、
     インライン画像を少し沈めて文字と目線を合わせる。角丸は画像に焼き込み済み。
     base.css のリセットが img を block にするので、ここだけ inline に戻す。 */
  .app-nav-mark {
    display: inline-block;
    width: 1.25em;
    height: 1.25em;
    vertical-align: -0.3em;
    margin-inline-end: var(--space-2);
  }

  .app-nav-name:hover {
    text-decoration: underline;
  }

  /* 会話の面のときだけ、表札の場所に立つ「戻る」。矢だけにしない ──
     かたちだけで意味を負わせず、言葉も添える(色や図形に頼らない、の続き)。
     指で押すので --tap-min。 */
  .app-nav-back {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    min-height: var(--tap-min);
    margin-inline-start: calc(var(--space-2) * -1);
    padding-inline: var(--space-2);
    font-weight: 700;
    text-decoration: none;
    color: inherit;
  }

  .app-nav-back:hover {
    text-decoration: underline;
  }

  .nav-top {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-1);
  }

  /* ラベルと未見の指標(数字・glyph)は一塊。上の帯では icon の隣に
     一行で、下の帯では icon の下に一行で ── どちらも同じ並び。 */
  .nav-text {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
  }

  .nav-label {
    white-space: nowrap;
  }

  /* direct の未見数。バッジにしない ── 赤も丸もなく、ただの数字。 */
  .notif-count {
    font-variant-numeric: tabular-nums;
  }

  /* 下の帯は、広い画面では存在しない。 */
  .nav-bottom {
    display: none;
  }

  @media (width <= 40rem) {
    /* 「流れ」は下の帯へ。上の帯には「棚」だけが、ことばを伏せて
       アイコンで残る(読み上げには .nav-label が生きている)。 */
    .nav-top .nav-flow {
      display: none;
    }
    .nav-top .nav-label {
      position: absolute;
      width: 1px;
      height: 1px;
      padding: 0;
      margin: -1px;
      overflow: hidden;
      clip: rect(0 0 0 0);
      white-space: nowrap;
      border: 0;
    }
    .nav-top :global(.nav-link) {
      padding-inline: var(--space-1);
    }

    /* 親指の帯。fixed で下に貼りつき、スクロールしても消えない。 */
    .nav-bottom {
      display: flex;
      --nav-ico-size: 1.5rem;
      position: fixed;
      inset: auto 0 0 0;
      z-index: var(--layer-bottom-nav);
      background: var(--color-surface);
      border-block-start: 1px solid var(--color-border);
      padding-block-end: env(safe-area-inset-bottom, 0px);
      /* 遷移のたびにページ高さや URL バーが動くと、fixed のこの帯は
         再ラスタライズされて中の線画 SVG が一瞬飛ぶことがある。独立した
         合成レイヤーに固定して、描き直しの巻き添えにしない。 */
      transform: translateZ(0);
      backface-visibility: hidden;
    }
    .nav-bottom .nav-link {
      flex: 1;
      flex-direction: column;
      gap: 2px;
      padding: var(--space-2) 0;
      border-radius: 0;
      font-size: 0.7rem;
      text-align: center;
      /* flex:1 でも、ラベルが nowrap だと中身の最小幅が効いて 5 つ並びが
         画面を超えることがある。0 まで縮めて宛がうことを許して、横の
         はみ出しを止める。 */
      min-width: 0;
    }

  }

  /* ── ナビのドロップダウン(ライブラリ / アバター) ───────────────
     棚を畳んだ二つの小さなメニュー。開くまで何も主張しない。面は
     StatusActions の .menu と同じ作法(枠だけ・影なし)で平らに。 */

  .nav-top :global(.nav-avatar) {
    width: 1.6rem;
    height: 1.6rem;
    border-radius: 999px;
    object-fit: cover;
    display: block;
  }


  .nav-menu-item {
    --nav-ico-size: 1.15em;
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-2) var(--space-3);
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--color-text-muted);
    font: inherit;
    font-size: var(--text-sm);
    text-decoration: none;
    text-align: start;
    white-space: nowrap;
    cursor: pointer;
  }
  .nav-menu-item:hover {
    background: var(--fill-soft);
    color: var(--color-text);
  }
  .nav-menu-item[aria-current='page'] {
    color: var(--color-text);
  }

  .nav-menu-sep {
    height: 1px;
    margin: var(--space-1) 0;
    background: var(--color-border);
  }
</style>
