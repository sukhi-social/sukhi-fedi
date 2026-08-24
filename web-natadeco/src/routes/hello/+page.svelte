<script lang="ts">
  import { t } from '$lib/i18n.svelte';
  import Hinata from '$lib/Hinata.svelte';
  import PageHeader from '$lib/PageHeader.svelte';
</script>

<PageHeader title={t().hello.title} />

<Hinata>
  <p>{t().hello.greeting}</p>
  <p>{t().hello.ask}</p>
  <p class="muted small">{t().hello.hint}</p>
</Hinata>

<a class="btn" href="/signup">{t().hello.start}</a>

<style>
  .small {
    font-size: 0.85rem;
  }
</style>
