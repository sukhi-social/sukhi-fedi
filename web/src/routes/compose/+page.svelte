<script lang="ts">
  // 書くための、書くだけの面。
  //
  // 前はタイムラインの上に composer を開いていた ── /timeline へ移って、
  // store で合図して、上までスクロールする。書いているあいだ、下では
  // 流れが続いていた。**書くことは、読むことの片手間ではない。**
  //
  // 一枚に一つだけ置く。下に流れは無く、戻る口が一つあり、送ったら
  // 元居たところへ帰る。
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { isLoggedIn } from '$lib/auth';
  import Composer from '$lib/components/Composer.svelte';
  import { t } from '$lib/i18n';

  onMount(() => {
    if (!isLoggedIn()) void goto('/');
  });

  // 送れたら、流れへ帰す。書いたものは、そこに出ている。
  function onPosted() {
    void goto('/timeline');
  }

  function onCancel() {
    if (typeof history !== 'undefined' && history.length > 1) history.back();
    else void goto('/timeline');
  }
</script>

<svelte:head><title>{$t('nav.compose')} — sukhi</title></svelte:head>

<header class="timeline page-head">
  <a class="chip" href="/timeline">{$t('common.backToTimeline')}</a>
  <h1>{$t('nav.compose')}</h1>
</header>

<section class="timeline compose-page">
  <Composer page onposted={onPosted} oncancel={onCancel} />
</section>
