<script lang="ts">
  import '../styles/app.css';
  import AppNav from '$lib/components/AppNav.svelte';
  import EmailNudge from '$lib/components/EmailNudge.svelte';
  import UpdateBanner from '$lib/components/UpdateBanner.svelte';
  import AnnouncementsBanner from '$lib/components/AnnouncementsBanner.svelte';
  import { devAutoLogin } from '$lib/auth';
  import type { Snippet } from 'svelte';

  // dev で VITE_DEV_TOKEN があれば、AppNav が mount する前にテストユーザー
  // の token を置いておく。本番では何もしない。
  devAutoLogin();

  let { children }: { children?: Snippet } = $props();
</script>

<AppNav />

<main class="wrap stack">
  {@render children?.()}
</main>

<AnnouncementsBanner />
<EmailNudge />
<UpdateBanner />
