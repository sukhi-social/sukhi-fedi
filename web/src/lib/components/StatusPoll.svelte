<script lang="ts">
  import type { Poll } from '#lib/api.js';
  import * as api from '#lib/api.js';
  import { t } from '#lib/i18n.js';

  // 投票は楽観更新せずサーバの集計をそのまま映す。投票後 / 締切後 / 既に
  // 投票済みは結果表示、それ以外は選択 UI。single choice は radio、
  // multiple は checkbox。
  let { poll: initial }: { poll: Poll } = $props();

  // ローカル state は投票結果の反映用。prop が差し替わったら sync する。
  let poll = $state<Poll | null>(null);
  let pollChoices = $state<number[]>([]);
  let pollVoting = $state(false);

  $effect(() => {
    poll = initial;
    pollChoices = [];
  });

  let pollTotal = $derived(poll ? Math.max(1, poll.votes_count) : 1);
  let pollClosed = $derived(!!poll && (poll.expired || !!poll.voted));

  function toggleChoice(idx: number) {
    if (!poll) return;
    if (poll.multiple) {
      pollChoices = pollChoices.includes(idx)
        ? pollChoices.filter((i) => i !== idx)
        : [...pollChoices, idx];
    } else {
      pollChoices = [idx];
    }
  }

  async function submitVote() {
    if (!poll || pollVoting || pollChoices.length === 0) return;
    pollVoting = true;
    try {
      poll = await api.votePoll(poll.id, pollChoices);
    } catch {
      // 投票に失敗したら選択は残したまま、また押せる状態に戻す。
    } finally {
      pollVoting = false;
    }
  }
</script>

{#if poll}
  <div class="poll" aria-label={$t('status.poll')}>
    {#if pollClosed}
      {#each poll.options as opt, i (i)}
        {@const votes = opt.votes_count ?? 0}
        {@const pct = Math.round((votes / pollTotal) * 100)}
        <div class="poll-result" class:mine={poll.own_votes?.includes(i)}>
          <div class="poll-bar" style={`width: ${pct}%`}></div>
          <span class="poll-label">{opt.title}</span>
          <span class="poll-pct">{pct}%</span>
        </div>
      {/each}
    {:else}
      {#each poll.options as opt, i (i)}
        <label class="poll-choice">
          <input
            type={poll.multiple ? 'checkbox' : 'radio'}
            name={`poll-${poll.id}`}
            checked={pollChoices.includes(i)}
            onchange={() => toggleChoice(i)}
          />
          <span>{opt.title}</span>
        </label>
      {/each}
      <button
        type="button"
        class="chip"
        disabled={pollVoting || pollChoices.length === 0}
        onclick={submitVote}
      >
        {pollVoting ? $t('common.sending') : $t('status.vote')}
      </button>
    {/if}
    <p class="poll-meta">
      {$t('status.votes', { n: poll.votes_count })}{poll.expired ? $t('status.pollClosed') : ''}
    </p>
  </div>
{/if}

<style>
  .poll {
    margin-top: 0.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
  }
  .poll-choice {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    cursor: pointer;
  }
  .poll-result {
    position: relative;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.25rem 0.5rem;
    border-radius: var(--radius-sm);
    overflow: hidden;
    background: var(--fill-soft);
  }
  .poll-bar {
    position: absolute;
    inset: 0 auto 0 0;
    background: var(--fill-active);
    z-index: 0;
  }
  .poll-result.mine .poll-bar {
    background: var(--fill-active-edge);
  }
  .poll-label,
  .poll-pct {
    position: relative;
    z-index: 1;
  }
  .poll-label {
    flex: 1;
  }
  .poll-pct {
    font-variant-numeric: tabular-nums;
  }
  .poll-meta {
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }
</style>
