<script lang="ts">
  import '../app.css';
  let { children } = $props();
</script>

<header>
  <div class="measure bar">
    <a class="mark" href="/">ナタデコ</a>
    <span class="muted">板は、デコ</span>
  </div>
</header>

<main class="measure">
  {@render children()}
</main>

<footer class="measure">
  <p class="muted">
    熱くも、冷たくもない場所を。
  </p>
</footer>

<style>
  header {
    border-bottom: 1px solid var(--line);
    background: var(--paper-raised);
  }

  .bar {
    display: flex;
    align-items: baseline;
    gap: 0.9rem;
    padding-top: 0.9rem;
    padding-bottom: 0.9rem;
  }

  .mark {
    font-weight: 600;
    letter-spacing: 0.04em;
    text-decoration: none;
  }

  main {
    padding-top: 1.75rem;
    padding-bottom: 3rem;
    min-height: 60vh;
  }

  footer {
    border-top: 1px solid var(--line);
    padding-top: 1rem;
    padding-bottom: 2rem;
  }
</style>
