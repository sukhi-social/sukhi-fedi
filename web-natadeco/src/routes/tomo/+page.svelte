<script lang="ts">
  import { goto } from '$app/navigation';
  import {
    listFriends,
    findPerson,
    signedIn,
    startOfToday,
    type Post,
    type Person
  } from '$lib/api';
  import { t } from '$lib/i18n.svelte';
  import Flow from '$lib/Flow.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  // 友デコ ── 板の一覧に並ぶけれど、板ではない。ここに書く場所は無く、
  // 流れているのは追っている人が言ったこと。読めるのは自分だけ。
  //
  // 描きかたは話す板と同じものを借りる。違うのは辺の種類（板を追うか、
  // 人を追うか）と、自分の投稿が入らないことだけ。
  let rows = $state<Post[]>([]);
  let loading = $state(true);
  let atToday = $state(true);
  let done = $state(false);
  let error = $state<string | null>(null);

  let q = $state('');
  let found = $state<Person[]>([]);
  let searching = $state(false);

  $effect(() => {
    if (!signedIn()) {
      void goto('/login?next=/tomo');
      return;
    }
    loading = true;
    listFriends({ since: startOfToday() })
      .then((r) => (rows = r))
      .catch(() => (error = t().tomo.loadError))
      .finally(() => (loading = false));
  });

  async function earlier() {
    const last = rows.at(-1);
    const more = await listFriends({ maxId: last ? String(last.id) : undefined });
    rows = [...rows, ...more];
    atToday = false;
    if (more.length === 0) done = true;
  }

  // `alice@example.tld` は、まだ知らない相手でも取りに行く（WebFinger）。
  async function search(e: SubmitEvent) {
    e.preventDefault();
    if (!q.trim() || searching) return;
    searching = true;
    try {
      const r = await findPerson(q.trim());
      found = r.accounts ?? [];
    } catch {
      found = [];
    } finally {
      searching = false;
    }
  }
</script>

<PageHeader title={t().tomo.title} subtitle={t().tomo.subtitle} />

<p class="muted small mine">{t().tomo.yoursOnly}</p>

<form class="find" onsubmit={search}>
  <input type="search" bind:value={q} placeholder={t().tomo.findPlaceholder} />
  <button class="btn" type="submit" disabled={searching || !q.trim()}>{t().tomo.find}</button>
</form>

{#if found.length > 0}
  <ul class="found">
    {#each found as p (p.id)}
      <li>
        <a href="/people/{p.id}">
          <img class="avatar" src={p.avatar} alt="" width="32" height="32" />
          <span>
            <strong>{p.display_name}</strong>
            <span class="muted small">@{p.acct}</span>
          </span>
        </a>
      </li>
    {/each}
  </ul>
{/if}

{#if loading}
  <p class="muted">{t().common.loading}</p>
{:else if error}
  <p class="error">{error}</p>
{:else if rows.length === 0}
  <p class="muted empty">{t().tomo.empty}</p>
{:else}
  <Flow bind:rows />

  {#if done}
    <p class="muted end">{t().board.end}</p>
  {:else if atToday}
    <p class="muted end">{t().flow.endToday}</p>
    <button class="btn" type="button" onclick={earlier}>{t().flow.earlier}</button>
  {:else}
    <button class="btn" type="button" onclick={earlier}>{t().board.more}</button>
  {/if}
{/if}

<p class="back"><a href="/">{t().common.toDecoList}</a></p>

<style>
  /* 他のデコと同じ一覧に並ぶ部屋なので、ここが自分だけのものだと
     見えていないと、うっかり「ここに書けば友達だけに見える」と
     読まれる。上に一行、はっきり置く。 */
  .mine {
    margin: 0 0 0.8rem;
  }

  .find {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 1rem;
  }

  .find input {
    flex: 1;
    min-width: 0;
  }

  .found {
    list-style: none;
    padding: 0;
    margin: 0 0 1.2rem;
    border: 1px solid var(--line);
    border-radius: var(--radius);
  }

  .found li + li {
    border-top: 1px solid var(--line);
  }

  .found a {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.5rem 0.7rem;
    text-decoration: none;
    color: inherit;
  }

  .avatar {
    border-radius: 50%;
    object-fit: cover;
    background: var(--sun-soft);
  }

  .empty,
  .end {
    margin: 1.5rem 0;
  }

  .back {
    margin-top: 2rem;
  }
</style>
