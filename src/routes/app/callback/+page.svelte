<script lang="ts">
  import { onMount } from 'svelte';
  import { completeLogin } from '$lib/auth';
  import { t } from '$lib/i18n.svelte';

  let error = $state<string | null>(null);

  onMount(async () => {
    const params = new URLSearchParams(window.location.search);
    const code = params.get('code');
    const state = params.get('state');
    const err = params.get('error');

    if (err) {
      error = t().callback.serverError(err);
      return;
    }
    if (!code || !state) {
      error = t().callback.noCode;
      return;
    }

    try {
      await completeLogin(code, state);
      const next = sessionStorage.getItem('nd.next');
      sessionStorage.removeItem('nd.next');
      window.location.assign(next && next.startsWith('/') ? next : '/');
    } catch (e) {
      error = e instanceof Error ? e.message : t().callback.failedTitle;
    }
  });
</script>

{#if error}
  <h1>{t().callback.failedTitle}</h1>
  <p class="muted">{error}</p>
  <p><a href="/">{t().common.toDecoList}</a></p>
{:else}
  <p class="muted">{t().callback.working}</p>
{/if}
