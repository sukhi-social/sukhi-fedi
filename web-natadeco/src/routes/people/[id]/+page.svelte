<script lang="ts">
  import { page } from '$app/state';
  import {
    getPerson,
    personPosts,
    relationships,
    follow,
    unfollow,
    signedIn,
    type Person,
    type Post
  } from '$lib/api';
  import { t } from '$lib/i18n.svelte';
  import Flow from '$lib/Flow.svelte';
  import PageHeader from '$lib/PageHeader.svelte';

  // 追う前に、その人を見る場所。natadeco のアカウントは本物の
  // fediverse actor なのに、これまでこの画面が無かった。
  const id = $derived(page.params.id ?? '');

  let person = $state<Person | null>(null);
  let rows = $state<Post[]>([]);
  let following = $state(false);
  let requested = $state(false);
  let busy = $state(false);
  let loading = $state(true);
  let error = $state<string | null>(null);

  $effect(() => {
    const who = id;
    loading = true;
    Promise.all([getPerson(who), personPosts(who).catch(() => [])])
      .then(([p, posts]) => {
        person = p;
        rows = posts;
      })
      .catch(() => (error = t().people.notFound))
      .finally(() => (loading = false));

    if (signedIn()) {
      relationships([who])
        .then(([r]) => {
          following = r?.following ?? false;
          requested = r?.requested ?? false;
        })
        .catch(() => {});
    }
  });

  async function toggle() {
    if (!person || busy) return;
    busy = true;
    try {
      const r = following ? await unfollow(person.id) : await follow(person.id);
      following = r.following;
      requested = r.requested;
    } catch {
      // 押せなかったときは黙って元のまま。ここで人の手を止めない。
    } finally {
      busy = false;
    }
  }
</script>

{#if loading}
  <p class="muted">{t().common.loading}</p>
{:else if !person}
  <p class="muted">{error ?? t().people.notFound}</p>
  <p><a href="/tomo">{t().people.backToTomo}</a></p>
{:else}
  <PageHeader title={person.display_name} subtitle="@{person.acct}">
    {#snippet actions()}
      {#if signedIn()}
        <button class="btn" class:ghost={following} type="button" disabled={busy} onclick={toggle}>
          {following ? t().people.unfollow : requested ? t().people.requested : t().people.follow}
        </button>
      {/if}
    {/snippet}
  </PageHeader>

  <div class="who">
    <img class="avatar" src={person.avatar} alt="" width="64" height="64" />
    <div>
      {#if person.note}<div class="note">{@html person.note}</div>{/if}
      <p class="muted small counts">
        {t().people.counts(person.statuses_count, person.following_count, person.followers_count)}
      </p>
      <p class="muted small"><a href={person.url} rel="noreferrer">{t().people.openRemote}</a></p>
    </div>
  </div>

  {#if rows.length === 0}
    <p class="muted empty">{t().people.noPosts}</p>
  {:else}
    <Flow bind:rows />
  {/if}

  <p class="back"><a href="/tomo">{t().people.backToTomo}</a></p>
{/if}

<style>
  .who {
    display: flex;
    gap: 0.9rem;
    align-items: flex-start;
    margin-bottom: 1.5rem;
  }

  .avatar {
    border-radius: 50%;
    object-fit: cover;
    background: var(--sun-soft);
    flex: none;
  }

  .note :global(p) {
    margin: 0 0 0.4rem;
  }

  .counts {
    margin: 0.2rem 0;
  }

  .empty {
    margin: 1.5rem 0;
  }

  .back {
    margin-top: 2rem;
  }
</style>
