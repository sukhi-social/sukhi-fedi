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
  import { goto, afterNavigate } from '$app/navigation';
  import { isLoggedIn, signOutServer } from '$lib/auth';
  import Avatar from './Avatar.svelte';
  import { currentAccount, type Account } from '$lib/api';
  import {
    directUnseen,
    ambientUnseen,
    refreshUnseen,
    startStream,
    stopStream
  } from '$lib/notify';
  import NavIcon, { type IconName } from '$lib/components/NavIcon.svelte';
  import NavMenu from '$lib/components/NavMenu.svelte';
  import NotifGlyph from '$lib/components/NotifGlyph.svelte';
  import { t, type TranslationKey } from '$lib/i18n';

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

  // 会話の面は「入った先」。ここは行き先を選ぶ場所ではなく、もう誰かと
  // 話している場所なので、流れの帯は畳んで、左上を戻る口にする ──
  // スマホのアプリが、話の画面でタブを消して ← を出すのと同じ約束。
  // (畳んだぶんの高さは、そのまま会話に返る。)
  let inThread = $derived(/^\/messages\/[^/]+\/?$/.test(page.url.pathname));
  let showBottomNav = $derived(loggedIn && !inThread);

  function sync() {
    loggedIn = isLoggedIn();
    if (loggedIn) {
      void refreshUnseen();
      void currentAccount().then((a) => (me = a));
      startStream();
    } else {
      me = null;
      stopStream();
    }
  }

  // 下の帯のぶんの余白は、帯が出ているときだけ。畳んだ面で余白だけ残ると、
  // 会話の下に理由のない空きができる。
  $effect(() => {
    document.body.classList.toggle('has-bottom-nav', showBottomNav);
    // 会話の面では、返信箱が画面の底に貼りつく。その下に本文の下余白が
    // 残ると、返事の下に理由のない空きができる(48px 実測)。
    document.body.classList.toggle('in-thread', inThread);
  });

  onMount(() => {
    sync();
    return () => {
      stopStream();
      if (typeof document !== 'undefined') {
        document.body.classList.remove('has-bottom-nav');
        document.body.classList.remove('in-thread');
      }
    };
  });

  afterNavigate(() => {
    sync();
  });

  // 読み上げと hover には、かたちでなく言葉で正直に。
  const notifHint = $derived.by(() => {
    const parts: string[] = [];
    if ($directUnseen > 0) parts.push($t('nav.notifDirect', { n: $directUnseen }));
    if ($ambientUnseen > 0) parts.push($t('nav.notifAmbient'));
    return parts.length > 0 ? parts.join(' / ') : null;
  });

  async function signOut() {
    await signOutServer();
    loggedIn = false;
    me = null;
    goto('/');
  }
</script>

<!-- 流れの一項目。どれもただのリンク(「書く」も /compose を持つように
     なったので、ここに分岐は無い)。通知だけ未見の指標を抱える。 -->
{#snippet flowLink(item: FlowItem)}
  {@const href = item.href}
  {@const isNotif = href === '/notifications'}
    <a
      class="nav-link nav-flow"
      {href}
      aria-current={page.url.pathname === href ? 'page' : undefined}
      aria-label={isNotif && notifHint ? `${$t(item.key)} — ${notifHint}` : undefined}
      title={isNotif ? (notifHint ?? undefined) : undefined}
    >
      <NavIcon name={item.icon} />
      <span class="nav-text">
        <span class="nav-label">{$t(item.key)}</span>
        {#if isNotif}
          {#if $directUnseen > 0}<span class="notif-count">{$directUnseen}</span>{/if}
          {#if $ambientUnseen > 0}<NotifGlyph count={$ambientUnseen} />{/if}
        {/if}
      </span>
    </a>
{/snippet}

<!-- ドロップダウンの中の一行(行き先リンク)。 -->
{#snippet menuLink(href: string, key: TranslationKey, icon: IconName)}
  <a
    class="nav-menu-item"
    role="menuitem"
    {href}
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

        <NavMenu ariaLabel={$t('nav.account')} triggerClass="nav-avatar-trigger">
          {#snippet trigger()}
            {#if me}
              <Avatar class="nav-avatar" src={me.avatar} name={me.display_name || me.username} />
            {:else}
              <NavIcon name="user" />
            {/if}
          {/snippet}
          {#snippet children()}
            {#if me}{@render menuLink(`/@${me.acct}`, 'nav.profile', 'user')}{/if}
            <div class="nav-menu-sep" role="separator"></div>
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
