<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<script>
  import { token } from './api.js';
  import { begin, finish } from './login.js';
  import { parse } from './format.js';
  import Public from './Public.svelte';
  import List from './List.svelte';
  import Read from './Read.svelte';
  import Suspensions from './Suspensions.svelte';

  let hash = $state(location.hash);
  let auth = $state(token.get());
  let count = $state(null);
  let notice = $state('');
  const route = $derived(parse(hash));
  // 道具の棚が出るのは、トークンがあるときだけ。トークンが無いのに道具の頁を開いたら、窓口に戻す。
  const inTools = $derived(route.name !== 'public' && auth !== '');

  $effect(() => {
    const on = () => (hash = location.hash);
    addEventListener('hashchange', on);
    return () => removeEventListener('hashchange', on);
  });

  // ログインから戻ってきたとき(?code=…)。トークンに替えて、申し込みへ。
  $effect(() => {
    finish().then((r) => {
      if (r === true) {
        auth = token.get();
        location.hash = '#/applications';
      } else if (r === false) notice = 'ログインが、うまくいきませんでした。もう一度、ためしてください。';
    });
  });
  function login() {
    notice = '';
    begin().catch(() => (notice = 'ログインを始められませんでした。'));
  }
  function close(why) {
    notice = typeof why === 'string' ? why : '';
    token.set('');
    auth = '';
    count = null;
    location.hash = '';
  }
</script>

<header class="bar">
  <a class="name" href="#/">gov<small>sukhi.social の窓口</small></a>
  {#if auth}
    <span class="who">管理する人として、ひらいています <button class="btn" onclick={() => close()}>閉じる</button></span>
  {/if}
</header>

<div class="frame" class:with-shelf={auth}>
  {#if auth}
    <nav class="shelf" aria-label="道具">
      <span class="label">迎える</span>
      <a href="#/applications" aria-current={route.name === 'list' || route.name === 'read' ? 'page' : undefined}>
        申し込み {#if count !== null}<span class="count">{count}</span>{/if}
      </a>
      <span class="label">守る</span>
      <a href="#/suspensions" aria-current={route.name === 'suspensions' ? 'page' : undefined}>配送のお休み</a>
    </nav>
  {/if}
  <main class="main">
    {#if route.name === 'public' || !inTools}
      <Public {auth} {notice} onlogin={login} />
    {:else if route.name === 'suspensions'}
      <Suspensions onexpired={() => close('ログインが、切れました。もう一度、ひらいてください。')} />
    {:else if route.name === 'list'}
      <List oncount={(n) => (count = n)} onexpired={() => close('ログインが、切れました。もう一度、ひらいてください。')} />
    {:else}
      <Read receipt={route.receipt} onexpired={() => close('ログインが、切れました。もう一度、ひらいてください。')} ondone={() => (count = count === null ? null : Math.max(0, count - 1))} />
    {/if}
  </main>
</div>
