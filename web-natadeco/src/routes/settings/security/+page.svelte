<script lang="ts">
  import { goto } from '$app/navigation';
  import { signedIn } from '$lib/api';
  import {
    fetchAuthState,
    registerPasskey,
    deletePasskey,
    requestReauthCode,
    type AuthState,
    type Passkey
  } from '$lib/auth';
  import { passkeySupported } from '$lib/webauthn';
  import { t, getLang } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  let auth = $state<AuthState | null>(null);
  let loading = $state(true);
  let canPasskey = $state(false);

  let nickname = $state('');
  let busy = $state(false);
  let error = $state<string | null>(null);

  // はずす前の本人確認。合言葉を持っている人は合言葉、持っていない人は
  // メールに届く6桁 ── どちらの道も、開くのは「はずす」を押してから。
  let removing = $state<number | null>(null);
  let password = $state('');
  let reauthCode = $state('');
  let reauthSent = $state(false);

  $effect(() => {
    if (!signedIn()) {
      void goto('/login?next=/settings/security');
      return;
    }
    canPasskey = passkeySupported();
    void load();
  });

  async function load() {
    try {
      auth = await fetchAuthState();
    } catch {
      auth = null;
    } finally {
      loading = false;
    }
  }

  function explain(e: unknown): string {
    const msg = e instanceof Error ? e.message : '';
    if (msg === 'already_registered') return t().security.errorDup;
    if (msg === 'reauth') return t().security.errorReauth;
    return t().security.errorGeneric;
  }

  function fmt(iso: string): string {
    return new Date(iso).toLocaleDateString(getLang() === 'ko' ? 'ko-KR' : 'ja-JP');
  }

  function label(pk: Passkey): string {
    return pk.nickname?.trim() || t().security.unnamed;
  }

  async function add(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = null;
    try {
      await registerPasskey(nickname.trim());
      nickname = '';
      await load();
    } catch (e) {
      // 認証器のダイアログを閉じただけのときは、何も言わない。
      if (!(e instanceof DOMException && e.name === 'NotAllowedError')) error = explain(e);
    } finally {
      busy = false;
    }
  }

  function startRemove(id: number) {
    removing = id;
    password = '';
    reauthCode = '';
    reauthSent = false;
    error = null;
  }

  function cancelRemove() {
    removing = null;
    error = null;
  }

  async function sendReauth() {
    if (busy) return;
    busy = true;
    error = null;
    try {
      await requestReauthCode();
      reauthSent = true;
    } catch (e) {
      error = explain(e);
    } finally {
      busy = false;
    }
  }

  async function confirmRemove(e: SubmitEvent) {
    e.preventDefault();
    if (busy || removing === null) return;
    busy = true;
    error = null;
    try {
      await deletePasskey(
        removing,
        auth?.has_password ? { password } : { reauth_code: reauthCode }
      );
      removing = null;
      await load();
    } catch (e) {
      error = explain(e);
    } finally {
      busy = false;
    }
  }
</script>

<PageHeader title={t().security.title} />

{#if loading}
  <p class="muted">{t().common.loading}</p>
{:else if !auth}
  <p class="muted">
    {t().settings.loadError.prefix}<a href="/login?next=/settings/security"
      >{t().settings.loadError.link}</a
    >{t().settings.loadError.suffix}
  </p>
{:else if !auth.manageable}
  <!-- bearer では読めても触れない(サーバの決め)。cookie を立てなおす。 -->
  <p class="muted">
    {t().security.signInAgain.prefix}<a href="/login?next=/settings/security"
      >{t().security.signInAgain.link}</a
    >{t().security.signInAgain.suffix}
  </p>
{:else}
  <p class="intro">{t().security.intro}</p>

  <div class="card stack">
    {#if auth.passkeys.length === 0}
      <p class="muted">{t().security.none}</p>
    {:else}
      <ul class="keys">
        {#each auth.passkeys as pk (pk.id)}
          <li>
            <div class="key">
              <span class="name">{label(pk)}</span>
              <span class="muted small">
                {t().security.added(fmt(pk.created_at))}
                ・{pk.last_used_at
                  ? t().security.lastUsed(fmt(pk.last_used_at))
                  : t().security.neverUsed}
              </span>
            </div>
            {#if removing === pk.id}
              <form class="remove stack" onsubmit={confirmRemove}>
                <p class="muted small">{t().security.removeIntro}</p>
                {#if auth.has_password}
                  <label>
                    <span class="muted">{t().security.password}</span>
                    <input
                      type="password"
                      bind:value={password}
                      required
                      autocomplete="current-password"
                    />
                  </label>
                {:else if !reauthSent}
                  <button class="btn" type="button" disabled={busy} onclick={sendReauth}>
                    {t().security.sendReauth}
                  </button>
                {:else}
                  <p class="muted small">{t().security.reauthSent}</p>
                  <label>
                    <span class="muted">{t().security.reauthCode}</span>
                    <input
                      type="text"
                      bind:value={reauthCode}
                      required
                      inputmode="numeric"
                      pattern="[0-9]{'{6}'}"
                    />
                  </label>
                {/if}
                <div class="row">
                  {#if auth.has_password || reauthSent}
                    <button class="btn" type="submit" disabled={busy}>
                      {busy ? t().security.removing : t().security.remove}
                    </button>
                  {/if}
                  <button class="quiet" type="button" onclick={cancelRemove}>
                    {t().security.cancel}
                  </button>
                </div>
              </form>
            {:else}
              <button class="quiet" type="button" onclick={() => startRemove(pk.id)}>
                {t().security.remove}
              </button>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </div>

  {#if canPasskey}
    <form class="card stack add" onsubmit={add}>
      <label>
        <span class="muted">{t().security.nickname}</span>
        <input type="text" bind:value={nickname} maxlength="200" />
      </label>
      <button class="btn" type="submit" disabled={busy}>
        {busy ? t().security.adding : t().security.add}
      </button>
    </form>
  {:else}
    <p class="muted add">{t().security.unsupported}</p>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}

  <p class="prose-small"><a href="/settings">{t().security.backToSettings}</a></p>
{/if}

<style>
  .intro {
    max-width: 32rem;
    margin: 0 0 1rem;
    line-height: 1.8;
  }

  .stack {
    display: grid;
    gap: 0.85rem;
    max-width: 32rem;
  }

  label {
    display: grid;
    gap: 0.3rem;
  }

  .keys {
    list-style: none;
    margin: 0;
    padding: 0;
    display: grid;
    gap: 0.9rem;
  }

  /* 鍵の名前と日付は縦に、はずすボタンは右端に。せまい画面では
     ボタンが下へ回る。 */
  .keys li {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
  }

  .keys li + li {
    border-top: 1px solid var(--line);
    padding-top: 0.9rem;
  }

  .key {
    display: grid;
    gap: 0.15rem;
  }

  .name {
    font-family: var(--font-round);
    font-weight: 700;
  }

  /* 消すほうのボタンは、足すほうより静かに ── 押し間違えるより、
     見つからないほうがましなので。タップ領域は 44px のまま。 */
  .quiet {
    display: inline-flex;
    align-items: center;
    min-height: 2.75rem;
    background: transparent;
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: 0.35rem 0.9rem;
    font-size: 0.85rem;
    color: var(--ink-soft);
    cursor: pointer;
  }

  .remove {
    flex-basis: 100%;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 0.8rem;
  }

  .add {
    margin-top: 1rem;
  }

  .small {
    font-size: 0.85rem;
  }

  .error {
    margin-top: 1rem;
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
  }

  .prose-small {
    margin-top: 1.25rem;
  }
</style>
