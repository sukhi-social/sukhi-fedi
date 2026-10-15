<script lang="ts">
  // ことばを選ぶ、ちいさなボタンの組。名前はその言語の文字で出す。
  import { t, locale, setLocale, LOCALES, LOCALE_NAMES } from '$lib/i18n';
</script>

<div class="lang-switch" role="group" aria-label={$t('lang.switch')}>
  {#each LOCALES as l (l)}
    <!-- 今の言語は aria-pressed だけで示す。global の chip[aria-pressed] が
         地を濃く塗るので、ここで地色を上書きすると白字が淡い灰に溶けていた。 -->
    <button
      type="button"
      class="chip"
      aria-pressed={$locale === l}
      onclick={() => setLocale(l)}
    >{LOCALE_NAMES[l]}</button>
  {/each}
</div>

<style>
  .lang-switch {
    display: inline-flex;
    gap: var(--space-2);
  }
</style>
