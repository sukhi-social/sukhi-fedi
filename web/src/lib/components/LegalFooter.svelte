<script lang="ts">
  import { t, locale } from '#lib/i18n.js';

  // 頁のいちばん下に、利用規約とプライバシーへの静かな入り口。
  // ただ読むためのリンクなので signup=true は付けない。ko のときは
  // ?lang=ko を添える(法的ページはサーバが焼いた一枚で、SPA の道では
  // ない ── SvelteKit は知らない道へのリンクを素の遷移に倒すので、
  // `<a>` のままでよい)。
  const termsHref = $derived($locale === 'ko' ? '/terms?lang=ko' : '/terms');
  const privacyHref = $derived($locale === 'ko' ? '/privacy?lang=ko' : '/privacy');
</script>

<footer class="legal-foot">
  <a href={termsHref}>{$t('signup.termsLink')}</a>
  <span class="sep" aria-hidden="true">·</span>
  <a href={privacyHref}>{$t('signup.privacyLink')}</a>
</footer>

<style>
  /* 罫線でそっと本文と切って、字は muted・中央に。本文と同じ measure 幅に
     そろえ、中央に寄せる(タイムラインのフッターと同じ見え方)。 */
  .legal-foot {
    max-width: var(--measure);
    margin-inline: auto;
    margin-block-start: var(--space-8);
    padding-block-start: var(--space-4);
    border-block-start: 1px solid var(--color-border);
    text-align: center;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }
  .legal-foot a {
    color: var(--color-text-muted);
  }
  .legal-foot a:hover {
    color: var(--color-text);
  }
  .legal-foot .sep {
    margin-inline: var(--space-2);
    color: var(--color-border-strong);
  }
</style>
