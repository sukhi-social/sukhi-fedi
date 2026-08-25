<script lang="ts">
  import { react, unreact, signedIn, type Reaction } from '$lib/api';
  import { t } from '$lib/i18n.svelte';
  import { renderGlyph } from '$lib/emoji';

  // 一件に付いた絵文字。返事を書くほど重くない「見たよ」を置ける場所。
  //
  // 数は出すけれど、並びには使わない ── 反応は返事であって点数ではない
  // ので、たくさん付いたものが上に行く仕組みは持たない。並び順はサーバが
  // 決めたまま（多い順→絵文字順）で、こちらでは触らない。
  //
  // 読むのは誰でも。入っていない人にはチップは見えるが、押せない。
  let { id, reactions = $bindable() }: { id: number; reactions: Reaction[] } = $props();

  // とりあえずの、少ない一組。多いほど選ぶのが仕事になるので、
  // 増やすより減らすほうに寄せてある。
  const OFFER = ['✨', '🌱', '☕', '👀', '💭', '🎉'];

  let open = $state(false);
  let busy = $state<string | null>(null);

  const mine = $derived(new Set(reactions.filter((r) => r.me).map((r) => r.name)));

  async function toggle(name: string) {
    if (!signedIn() || busy) return;
    busy = name;
    try {
      const res = mine.has(name) ? await unreact(id, name) : await react(id, name);
      reactions = res.reactions ?? [];
      open = false;
    } catch {
      // 押せなかったときは、黙って元のまま。反応は本文ではないので、
      // ここで人の手を止めない。
    } finally {
      busy = null;
    }
  }
</script>

<div class="reactions">
  {#each reactions as r (r.name)}
    <button
      type="button"
      class="chip"
      class:mine={r.me}
      disabled={!signedIn() || busy === r.name}
      onclick={() => toggle(r.name)}
      title={r.name}
    >
      {#if r.url}
        <img src={r.url} alt={r.name} width="18" height="18" />
      {:else}
        <span class="glyph">{@html renderGlyph(r.name)}</span>
      {/if}
      <span class="count">{r.count}</span>
    </button>
  {/each}

  {#if signedIn()}
    <button
      type="button"
      class="chip add"
      aria-expanded={open}
      onclick={() => (open = !open)}
      title={t().reactions.add}
    >
      {open ? '×' : '+'}
    </button>

    {#if open}
      <span class="offer">
        {#each OFFER as e (e)}
          <button
            type="button"
            class="chip"
            class:mine={mine.has(e)}
            disabled={busy === e}
            onclick={() => toggle(e)}
          >
            <span class="glyph">{@html renderGlyph(e)}</span>
          </button>
        {/each}
      </span>
    {/if}
  {/if}
</div>

<style>
  .reactions {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 0.3rem;
  }

  .chip {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    padding: 0.1rem 0.45rem;
    border: 1px solid var(--line);
    border-radius: 999px;
    background: var(--paper-raised);
    color: var(--ink-soft);
    font: inherit;
    font-size: 0.85rem;
    line-height: 1.6;
    cursor: pointer;
  }

  .chip:disabled {
    cursor: default;
  }

  /* 自分が押したものは、囲いを陽の色に。塗りつぶさないのは、
     押していないものが「押されていない」に見えすぎないため。 */
  .chip.mine {
    border-color: var(--sun);
    background: var(--sun-soft);
    color: var(--ink);
  }

  .chip.add {
    color: var(--ink-soft);
    min-width: 1.9rem;
    justify-content: center;
  }

  .glyph {
    font-size: 1rem;
  }

  .count {
    font-variant-numeric: tabular-nums;
  }

  .offer {
    display: inline-flex;
    flex-wrap: wrap;
    gap: 0.3rem;
    padding: 0.2rem;
    border: 1px solid var(--line);
    border-radius: var(--radius);
    background: var(--paper);
  }

  img {
    vertical-align: -0.2em;
  }
</style>
