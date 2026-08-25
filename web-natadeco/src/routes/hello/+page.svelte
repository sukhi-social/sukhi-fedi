<script lang="ts">
  import { t } from '$lib/i18n.svelte';
  import Hinata from '$lib/Hinata.svelte';
  import PageHeader from '$lib/PageHeader.svelte';
  import { isRevealed, toggleRevealed } from '$lib/hinataVisibility.svelte';
</script>

<PageHeader title={t().hello.title} />

<Hinata side="right" big>
  <p>{t().hello.greeting}</p>
  <p>{t().hello.aiNotice}</p>
</Hinata>

<div class="switch-main">
  <button
    type="button"
    class="switch"
    role="switch"
    aria-checked={isRevealed()}
    aria-label={isRevealed() ? t().hinata.hide : t().hinata.reveal}
    onclick={toggleRevealed}
  >
    <span class="switch-track">
      <span class="switch-knob"></span>
    </span>
  </button>
  <span class="switch-label">{isRevealed() ? t().hinata.hide : t().hinata.reveal}</span>
</div>

<a class="btn" href="/signup">{t().hello.start}</a>

<style>
  .switch-main {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    margin: 1rem 0 1.4rem;
  }

  .switch-label {
    font-family: var(--font-round);
  }

  .switch {
    display: block;
    padding: 0;
    border: none;
    background: none;
    cursor: pointer;
  }

  .switch-track {
    display: block;
    width: 3.4rem;
    height: 1.8rem;
    border-radius: 999px;
    background: var(--blush);
    border: 1px solid var(--sun);
    position: relative;
    transition: background 0.15s ease;
  }

  .switch[aria-checked='true'] .switch-track {
    background: var(--sun);
  }

  .switch-knob {
    position: absolute;
    top: 1px;
    left: 1px;
    width: 1.55rem;
    height: 1.55rem;
    border-radius: 50%;
    background: #fff;
    transition: transform 0.15s ease;
  }

  .switch[aria-checked='true'] .switch-knob {
    transform: translateX(1.6rem);
  }
</style>
