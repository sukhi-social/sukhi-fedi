<script lang="ts">
  import '../styles/app.css';
  import AppNav from '#lib/components/AppNav.svelte';
  import EmailNudge from '#lib/components/EmailNudge.svelte';
  import Feedback from '#lib/components/Feedback.svelte';
  import DeliveryToasts from '#lib/components/DeliveryToasts.svelte';
  import UpdateBanner from '#lib/components/UpdateBanner.svelte';
  import AnnouncementsBanner from '#lib/components/AnnouncementsBanner.svelte';
  import { devAutoLogin } from '#lib/auth.js';
  import { registerServiceWorker } from '#lib/pwa.js';
  import { installForesight } from '#lib/foresight.js';
  import { applyPlatform } from '#lib/ux/platform.js';
  import type { Snippet } from 'svelte';

  // dev で VITE_DEV_TOKEN があれば、AppNav が mount する前にテストユーザー
  // の token を置いておく。本番では何もしない。
  devAutoLogin();

  // ホーム画面に入れられるようにする。dev では何もしない。
  registerServiceWorker();

  // リンクへ向かう「意図」でルートを先読みする。app.html の hover 先読みは
  // 外してあるので、リンクの温めはここが一手に引き受ける。
  installForesight();

  // どの OS か(粗いヒント)を <html data-platform> に置く。CSS の --tap-min が
  // これを読む。UX 契約の ── docs/UX_CONTRACT.md。
  applyPlatform();

  let { children }: { children?: Snippet } = $props();
</script>

<AppNav />

<main class="wrap stack">
  <!-- お知らせの類は、本文の手前に。以前は画面下に浮かせていたが、
       浮かせるぶんだけ下にあるものを覆っていた(タイムラインの下三分の一、
       DM の composer)。流れに置けば、来たときに目に入って、読み進めれば
       流れて消える ── 追いかけてこない。 -->
  <AnnouncementsBanner />
  <EmailNudge />
  <UpdateBanner />

  {@render children?.()}

  <Feedback />
</main>

<DeliveryToasts />
