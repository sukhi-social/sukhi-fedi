<script lang="ts">
  import { onMount } from 'svelte';
  import { goToCheck, saveSignupDraft, loadSignupDraft } from '$lib/auth';
  import { getInviteRequired } from '$lib/api';
  import { t, locale } from '$lib/i18n';
  import LangSwitch from '$lib/components/LangSwitch.svelte';

  // フォームが家。はじめる前に「ここがどんな場所か」を読んでもらえるよう、
  // 上にそっと誘いを置き、利用規約のページ(/terms?signup=true ── 一番下に
  // 「読みました」で戻れる)へ送る。同意の瞬間は、実際にアカウントが
  // できる「作る」ボタンに結ぶ ── 読んだだけでは同意にならないので、その
  // すぐ脇に、利用規約とプライバシーポリシーを名指し・リンクした一文を
  // 置く。6桁コードの送信と入力は /check ─ Anubis の通り道 ─ の上で行わ
  // れるので、ここからメールが出ることは無い。
  let username = $state('');
  let email = $state('');
  let invite_code = $state('');
  let error = $state<string | null>(null);
  let restored = $state(false);
  let agreed = $state(false);
  // 招待コードの欄を出すかどうか。訊き終わるまでは出したままにしておく
  // ── 要るのに隠れている、が一番こまる。
  let invite_required = $state(true);

  // 利用規約・プライバシーは、どちらも signup=true(末尾に「読みました」で
  // 戻れるページ)へ。誘いも同意チェックも、同じ先・同じタブ。読みに行く
  // 直前に saveOnLeave が入力を下書きへ残すので、戻ってきても消えない。
  const termsHref = $derived(
    $locale === 'ko' ? '/terms?signup=true&lang=ko' : '/terms?signup=true'
  );
  const privacyHref = $derived(
    $locale === 'ko' ? '/privacy?signup=true&lang=ko' : '/privacy?signup=true'
  );

  // 文は一文のまま辞書に持ち、リンクだけ差し込む(語順・助詞は言語ごとに
  // 一文の中で完結する)。差すのは内部の固定パスと自前の語だけ ── ユーザ
  // 入力は混ざらないので {@html} で安全に描ける。
  const termsAnchor = $derived(`<a href="${termsHref}">${$t('signup.termsLink')}</a>`);
  const privacyAnchor = $derived(`<a href="${privacyHref}">${$t('signup.privacyLink')}</a>`);

  // /check で失敗して戻ってきた人のために下書きを復元する。email_proof が
  // 残っていれば /check はコードの段を飛ばすので、ここでは気にしなくていい。
  onMount(() => {
    getInviteRequired().then((v) => (invite_required = v));

    const d = loadSignupDraft();
    if (d) {
      restored = true;
      username = d.username ?? '';
      invite_code = d.invite_code ?? '';
      email = d.email ?? '';
    }
  });

  // 入力(なまえ・招待コード・メール)を下書きへ残す。同じアドレスのまま
  // なら前の証明も持ち越す(20分以内ならコードの打ち直しが要らない)。
  function persist() {
    const d = loadSignupDraft();
    saveSignupDraft({
      username,
      invite_code,
      email,
      ...(d?.email_proof && d.email === email ? { email_proof: d.email_proof } : {})
    });
  }

  // 入力があるあいだ、下書きへ自動保存する ── 利用規約・プライバシーを
  // 読みに行って戻っても消えないように。空のうちは保存しない(意味のない
  // 「つづきから」を出さないため)。
  $effect(() => {
    if (username || invite_code || email) persist();
  });

  function submit() {
    error = null;
    persist();
    goToCheck('signup');
  }
</script>

<div class="measure">
  <section class="hero">
    <h1>{$t('signup.title')}</h1>
    <p class="tagline">{$t('signup.tagline')}</p>
  </section>

  <!-- いきなり規約にせず、フォームの上からそっと誘う。 -->
  <p class="read-first">{@html $t('signup.readFirst', { link: termsAnchor })}</p>

  {#if error}
    <p class="error">{error}</p>
  {/if}
  {#if restored}
    <p class="prose-small">{$t('signup.draftRestored')}</p>
  {/if}

  <form
    class="form stack"
    onsubmit={(e) => {
      e.preventDefault();
      submit();
    }}
  >
    <label class="stack-tight">
      <span>{$t('signup.email')}</span>
      <input
        type="email"
        bind:value={email}
        autocomplete="email"
        autocapitalize="none"
        spellcheck="false"
        required
      />
      <span class="help">{$t('signup.emailHelp')}</span>
    </label>

    <label class="stack-tight">
      <span>{$t('signup.handle')}</span>
      <div class="handle-field">
        <span class="handle-at" aria-hidden="true">@</span>
        <input
          type="text"
          bind:value={username}
          autocomplete="username"
          pattern="[a-z0-9_]{'{1,30}'}"
          title={$t('signup.handleTitle')}
          required
        />
      </div>
      <span class="help">{$t('signup.handleHelpPre')}<code>@usagi_05</code></span>
    </label>

    {#if invite_required}
      <label class="stack-tight">
        <span>{$t('signup.inviteCode')}</span>
        <input type="text" bind:value={invite_code} autocomplete="off" required />
      </label>
    {/if}

    <!-- 同意は、自分でチェックする ── 受け身の「〜になります」ではなく、
         能動の「同意します／동의해요」。韓国では受け身の言い回しがあまり
         使われないので、明示チェックのほうが素直。利用規約とプライバシー
         ポリシーを名指してリンクする。 -->
    <label class="agree">
      <input type="checkbox" bind:checked={agreed} required />
      <span>{@html $t('signup.agree', { terms: termsAnchor, privacy: privacyAnchor })}</span>
    </label>

    <button type="submit" class="btn px-6 py-2" disabled={!agreed}>{$t('signup.create')}</button>
  </form>

  <p class="prose-small after-form">
    {$t('signup.haveAccountPre')}<a href="/login">{$t('signup.haveAccountLink')}</a>{$t(
      'signup.haveAccountPost'
    )}
  </p>
  <p class="prose-small"><a href="/">{$t('signup.backToFront')}</a></p>

  <section class="section" style="text-align: center; margin-top: var(--space-5);">
    <LangSwitch />
  </section>
</div>

<style>
  /* いきなり規約に飛ばさない、はじめの誘い。目立たせすぎず、でも見落とさ
     ない ── やわらかい囲み。 */
  .read-first {
    border: 1px solid var(--color-border);
    background: var(--fill-soft);
    border-radius: var(--radius);
    padding: var(--space-3) var(--space-4);
    margin-bottom: var(--space-8);
    font-size: 0.95rem;
    line-height: 1.8;
  }

  /* 同意チェック ── 箱と文を横に、文頭にそろえる。 */
  .agree {
    display: flex;
    align-items: flex-start;
    gap: 0.55rem;
    font-size: 0.9rem;
    line-height: 1.5;
    color: var(--color-text);
  }
  .agree input[type='checkbox'] {
    margin-top: 0.2rem;
    flex: 0 0 auto;
  }

  /* 「作る」と、その下の副リンク(ログイン・表のページへ)の間にひと呼吸。 */
  .after-form {
    margin-top: var(--space-6);
  }
</style>
