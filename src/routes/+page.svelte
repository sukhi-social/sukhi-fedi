<script lang="ts">
  import { listDecos, createDeco, getCurrentAccount, type Deco } from '$lib/api';

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
  let saving = $state(false);

  $effect(() => {
    listDecos()
      .then((d) => (decos = d))
      .catch(() => (error = '板の一覧が読めませんでした'))
      .finally(() => (loading = false));

    getCurrentAccount().then((a) => (isAdmin = a?.isAdmin ?? false));
  });

  async function open(e: SubmitEvent) {
    e.preventDefault();
    saving = true;
    error = null;
    try {
      const made = await createDeco({ slug, name, description: description || undefined });
      decos = [...decos, made].sort((a, b) => a.name.localeCompare(b.name, 'ja'));
      slug = name = description = '';
      opening = false;
    } catch {
      error = 'その名前では立てられませんでした（すでにある名前か、使えない形かも）';
    } finally {
      saving = false;
    }
  }
</script>

<h1>デコ</h1>
<p class="muted intro">板が「デコ」です。好きなところに座ってください。</p>

{#if loading}
  <p class="muted">よみこみ中</p>
{:else if decos.length === 0}
  <p class="muted">まだ、どの板もありません。</p>
{:else}
  <ul class="list">
    {#each decos as deco (deco.id)}
      <li class="card">
        <a class="name" href="/{deco.slug}">{deco.name}</a>
        {#if deco.description}<p class="desc">{deco.description}</p>{/if}
        <p class="muted">{deco.post_count} 件</p>
      </li>
    {/each}
  </ul>
{/if}

{#if error}<p class="error">{error}</p>{/if}

{#if isAdmin}
  {#if opening}
    <form class="card open" onsubmit={open}>
      <label>
        <span class="muted">名前</span>
        <input type="text" bind:value={name} required maxlength="60" />
      </label>
      <label>
        <span class="muted">URL に出る名前（英小文字・数字・- _）</span>
        <input type="text" bind:value={slug} required pattern="[a-z0-9][a-z0-9_\-]&#123;0,29&#125;" />
      </label>
      <label>
        <span class="muted">どんな板か（なくてもいい）</span>
        <textarea bind:value={description} rows="2" maxlength="2000"></textarea>
      </label>
      <div class="row">
        <button class="btn" type="submit" disabled={saving}>立てる</button>
        <button class="btn ghost" type="button" onclick={() => (opening = false)}>やめる</button>
      </div>
    </form>
  {:else}
    <button class="btn" type="button" onclick={() => (opening = true)}>板を立てる</button>
  {/if}
{/if}

<style>
  h1 {
    font-size: 1.4rem;
    margin: 0 0 0.25rem;
  }

  .intro {
    margin: 0 0 1.5rem;
  }

  .list {
    list-style: none;
    margin: 0 0 1.5rem;
    padding: 0;
    display: grid;
    gap: 0.75rem;
  }

  .name {
    font-family: var(--font-round);
    font-weight: 700;
    font-size: 1.05rem;
    text-decoration: none;
  }

  .desc {
    margin: 0.35rem 0 0;
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
</style>
