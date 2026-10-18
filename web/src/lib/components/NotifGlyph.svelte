<script lang="ts">
  // 静かな通知(ambient)の「景色」。数字を出すかわりに、未見の量で
  // かたちが育つ: 、→ 。→ w → Λ → A → 木。
  //
  // 文字そのものは使わない(「w」は日本語の画面では笑ってしまうし、
  // 「A」はアルファベットに読まれる)。点→満ちた円→起伏→山→構造→木、
  // という成り立ちだけを borrowed して、ちいさなシルエットで描く。
  // 段階の境い目は読めなくていい — 離れていた間に変わったと感じられる
  // ことが目的で、木が上限(それ以上は増えて見えない)。
  //
  // 色は currentColor。chip の文字色にそのまま従うので、ここでは
  // 何も主張しない。動きもつけない — 変わる瞬間は誰も見ないから。
  let { count }: { count: number } = $props();

  // 0 は呼び出し側で出さない想定だけれど、来ても黙って空にする。
  const stage = $derived(
    count <= 0 ? 0 : count === 1 ? 1 : count <= 3 ? 2 : count <= 6 ? 3 : count <= 11 ? 4 : count <= 19 ? 5 : 6
  );
</script>

{#if stage > 0}
  <svg class="notif-glyph" viewBox="0 0 12 12" aria-hidden="true">
    {#if stage === 1}
      <!-- 、— 点がひとつ -->
      <circle cx="6" cy="7.5" r="1.7" fill="currentColor" />
    {:else if stage === 2}
      <!-- 。— 満ちて、ひとまとまりに -->
      <circle cx="6" cy="6.5" r="3" fill="none" stroke="currentColor" stroke-width="1.5" />
    {:else if stage === 3}
      <!-- w — 起伏。静かだったものが、すこし動き出す -->
      <path
        d="M1.5 8.5 Q3.1 5.5 4.75 8.5 Q6.4 5.5 8 8.5 Q9.2 6.3 10.5 8.5"
        fill="none"
        stroke="currentColor"
        stroke-width="1.4"
        stroke-linecap="round"
      />
    {:else if stage === 4}
      <!-- Λ — 上に伸びる -->
      <path
        d="M2.5 9.5 L6 2.8 L9.5 9.5"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    {:else if stage === 5}
      <!-- A — 山に横棒が入って、立つものになる -->
      <path
        d="M2.5 9.5 L6 2.8 L9.5 9.5 M4.2 6.9 L7.8 6.9"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    {:else}
      <!-- 木 — ここが上限。これ以上は、木のまま -->
      <line x1="6" y1="10.5" x2="6" y2="6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
      <circle cx="6" cy="4.4" r="3" fill="currentColor" />
    {/if}
  </svg>
{/if}

<style>
  .notif-glyph {
    width: 0.9em;
    height: 0.9em;
    vertical-align: -0.1em;
    margin-inline-start: var(--space-1);
  }
</style>
