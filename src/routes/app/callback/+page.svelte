<script lang="ts">
  import { onMount } from 'svelte';
  import { completeLogin } from '$lib/auth';

  let error = $state<string | null>(null);

  onMount(async () => {
    const params = new URLSearchParams(window.location.search);
    const code = params.get('code');
    const state = params.get('state');
    const err = params.get('error');

    if (err) {
      error = `サーバから: ${err}`;
      return;
    }
    if (!code || !state) {
      error = 'コードが見当たりません';
      return;
    }

    try {
      await completeLogin(code, state);
      const next = sessionStorage.getItem('nd.next');
      sessionStorage.removeItem('nd.next');
      window.location.assign(next && next.startsWith('/') ? next : '/');
    } catch (e) {
      error = e instanceof Error ? e.message : '入れませんでした';
    }
  });
</script>

{#if error}
  <h1>入れませんでした</h1>
  <p class="muted">{error}</p>
  <p><a href="/">デコの一覧へ</a></p>
{:else}
  <p class="muted">入っています…</p>
{/if}
