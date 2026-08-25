<script lang="ts">
  import { listDecos, createDeco, getCurrentAccount, localized, type Deco } from '$lib/api';
  import { t, getLang } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';
  import LangTabs from '$lib/LangTabs.svelte';

  let decos = $state<Deco[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);

  // 板を立てられるのは admin だけ ── 板の数を、誰かが見て決める場所に
  // しておく(natadeco が小さいうち)。
  let isAdmin = $state(false);

  // 板を立てる欄は、押されるまで閉じている。一覧を開いた人の目的は
  // たいてい「読む」なので、作る欄が先に目に入らないように。
  let opening = $state(false);
  let slug = $state('');
  let name = $state('');
  let description = $state('');
  let nameKo = $state('');
  let descriptionKo = $state('');
  let lang = $state<'ja' | 'ko'>(getLang());
  let saving = $state(false);

  $effect(() => {
    listDecos()
      .then((d) => (decos = d))
      .catch(() => (error = t().home.loadError))
      .finally(() => (loading = false));

    getCurrentAccount().then((a) => (isAdmin = a?.isAdmin ?? false));
  });

  // どちらの言語で立ててもいい ── 日本語欄が必須、ではない。埋まって
  // いるほうの名前がそのまま主になる。
  // 立てるときに決める、この板の届きかた。二つの軸を一つの問いにして
  // いる ── 表札(外から見つかるか)と、書いたものの出発点(どこまで届くか)。
  // 別々にも持てるが、立てる人に二度訊くほどの違いは、まだ無い。
  let reach = $state<'open' | 'inside'>('open');
  let kind = $state<'thread' | 'talk'>('thread');

  const jaComplete = $derived(!!name.trim());
  const koComplete = $derived(!!nameKo.trim());
  const canSubmit = $derived(jaComplete || koComplete);

  async function open(e: SubmitEvent) {
    e.preventDefault();
    if (!canSubmit || saving) return;
    saving = true;
    error = null;
    try {
      const made = await createDeco({
        ...(jaComplete
          ? {
              slug,
              name,
              description: description || undefined,
              name_i18n: koComplete ? { ko: nameKo.trim() } : undefined,
              description_i18n:
                koComplete && descriptionKo.trim() ? { ko: descriptionKo.trim() } : undefined
            }
          : { slug, name: nameKo.trim(), description: descriptionKo || undefined }),
        local_only: reach === 'inside',
        has_actor: reach === 'open',
        kind
      });
      decos = [...decos, made].sort((a, b) => a.name.localeCompare(b.name, 'ja'));
      slug = name = description = nameKo = descriptionKo = '';
      reach = 'open';
      kind = 'thread';
      lang = getLang();
      opening = false;
    } catch {
      error = t().home.createError;
    } finally {
      saving = false;
    }
  }
</script>

<PageHeader title={t().home.title} subtitle={t().home.subtitle} />

{#if loading}
  <p class="muted">{t().common.loading}</p>
{:else if decos.length === 0}
  <p class="muted">{t().home.empty}</p>
{:else}
  <ul class="list">
    {#each decos as deco (deco.id)}
      <li class="card">
        <a class="name" href="/d/{deco.slug}"
          >{localized(deco.name, deco.name_i18n)}{t().home.separator}<span class="deco-suffix"
            >{t().home.title}</span
          ></a
        >
        {#if deco.description}
          <p class="desc muted">{localized(deco.description, deco.description_i18n)}</p>
        {/if}
        <p class="muted">{t().home.postCount(deco.post_count)}</p>
      </li>
    {/each}
  </ul>
{/if}

{#if error}<p class="error">{error}</p>{/if}

{#if isAdmin}
  {#if opening}
    <form class="card open" onsubmit={open}>
      <label>
        <span class="muted">{t().home.fields.slug}</span>
        <input type="text" bind:value={slug} required pattern="[a-z0-9][a-z0-9_\-]&#123;0,29&#125;" />
      </label>

      <LangTabs bind:active={lang} />

      {#if lang === 'ja'}
        <label>
          <span class="muted">{t().home.fields.name}</span>
          <input type="text" bind:value={name} maxlength="60" />
        </label>
        <label>
          <span class="muted">{t().home.fields.description}</span>
          <textarea bind:value={description} rows="2" maxlength="2000"></textarea>
        </label>
      {:else}
        <label>
          <span class="muted">{t().home.fields.name}</span>
          <input type="text" bind:value={nameKo} maxlength="60" />
        </label>
        <label>
          <span class="muted">{t().home.fields.description}</span>
          <textarea bind:value={descriptionKo} rows="2" maxlength="2000"></textarea>
        </label>
      {/if}

      <fieldset class="reach">
        <legend class="muted">{t().decoKind.legend}</legend>
        <label class="check">
          <input type="radio" bind:group={kind} value="thread" />
          <span>
            {t().decoKind.threadLabel}
            <span class="muted small">{t().decoKind.threadHint}</span>
          </span>
        </label>
        <label class="check">
          <input type="radio" bind:group={kind} value="talk" />
          <span>
            {t().decoKind.talkLabel}
            <span class="muted small">{t().decoKind.talkHint}</span>
          </span>
        </label>
      </fieldset>

      <fieldset class="reach">
        <legend class="muted">{t().decoReach.legend}</legend>
        <label class="check">
          <input type="radio" bind:group={reach} value="open" />
          <span>
            {t().decoReach.openLabel}
            <span class="muted small">{t().decoReach.openHint}</span>
          </span>
        </label>
        <label class="check">
          <input type="radio" bind:group={reach} value="inside" />
          <span>
            {t().decoReach.insideLabel}
            <span class="muted small">{t().decoReach.insideHint}</span>
          </span>
        </label>
      </fieldset>

      <div class="row">
        <button class="btn" type="submit" disabled={saving || !canSubmit}>{t().home.submit}</button>
        <button class="btn ghost" type="button" onclick={() => (opening = false)}>{t().home.cancel}</button>
      </div>
      {#if !canSubmit && (name.trim() || nameKo.trim())}
        <p class="muted small">{t().home.needOneLang}</p>
      {/if}
    </form>
  {:else}
    <button class="btn" type="button" onclick={() => (opening = true)}>{t().home.openForm}</button>
  {/if}
{/if}

<footer class="legal-foot">
  <a href={getLang() === 'ko' ? '/terms?lang=ko' : '/terms'}>{t().footer.terms}</a>
  <span class="sep" aria-hidden="true">·</span>
  <a href={getLang() === 'ko' ? '/privacy?lang=ko' : '/privacy'}>{t().footer.privacy}</a>
</footer>

<style>
  .list {
    list-style: none;
    margin: 0 0 1.25rem;
    padding: 0;
    display: grid;
    gap: 0.75rem;
  }

  /* 板の名前は、一覧でいちばん目に留まってほしい文字。1.05rem のままだと
     --type-scale を掛けたときに地の文(1.0625rem 基準)より小さくなって
     しまい(逆転)、下の説明文より板名のほうが小さく見えていた。
     .body h2 と同じ 1.15rem に上げて、確実に地の文より大きくする。 */
  .name {
    font-family: var(--font-round);
    font-weight: 700;
    font-size: calc(1.15rem * var(--type-scale));
    text-decoration: none;
  }

  .deco-suffix {
    font-weight: 400;
    font-size: calc(1.15rem * var(--type-scale));
    color: var(--ink-soft);
  }

  .desc {
    margin: 0.35rem 0 0;
  }

  .small {
    font-size: 0.78rem;
  }

  .open {
    display: grid;
    gap: 0.85rem;
    margin-top: 0.5rem;
  }

  label {
    display: grid;
    gap: 0.3rem;
  }

  /* 板の届きかた。選ぶのは一度きりなので、説明を選択肢の中に置く ──
     別に注釈を出すと、どちらの話か目で追うことになる。 */
  .reach {
    border: 1px solid var(--line);
    border-radius: var(--radius);
    padding: 0.6rem 0.8rem;
    display: grid;
    gap: 0.5rem;
  }

  .reach legend {
    padding: 0 0.3rem;
  }

  /* 印と言葉が横に並ぶ一行 ── 他の欄は上下に組むので、ここだけ別に。 */
  .check {
    display: flex;
    align-items: start;
    gap: 0.5rem;
  }

  .check input {
    width: auto;
    min-width: 0;
    margin-top: 0.25rem;
  }

  .check span span {
    display: block;
  }

  .row {
    display: flex;
    gap: 0.6rem;
  }

  .ghost {
    background: transparent;
  }

  .error {
    color: var(--ink);
    background: var(--sun-soft);
    border-radius: var(--radius);
    padding: 0.6rem 0.9rem;
  }

  /* 一覧のいちばん下に、利用規約とプライバシーへの静かな入り口。
     罫線でそっと切って、字は muted・中央に(sukhi-fedi の timeline
     フッターと同じ型)。 */
  .legal-foot {
    margin-top: 2rem;
    padding-top: 1rem;
    border-top: 1px solid var(--line);
    text-align: center;
    font-size: 0.85rem;
    color: var(--ink-soft);
  }

  .legal-foot a {
    color: var(--ink-soft);
  }

  .legal-foot a:hover {
    color: var(--ink);
  }

  .legal-foot .sep {
    margin-inline: 0.5rem;
  }
</style>
