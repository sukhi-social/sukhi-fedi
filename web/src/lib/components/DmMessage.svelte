<script lang="ts">
  // 会話の中の一通。
  //
  // タイムラインの投稿カードは、ここには重すぎる ── 一通ごとに
  // アバター・名前・ハンドル・時刻・丸ボタン五つ。会話は「誰が・何を」で
  // 足りるし、ブーストも引用も、DM には意味がない。
  //
  // Zulip の平らで読みやすいところに、LINE のまとまりを足すあたり:
  //   ・続けて喋ったぶんは、名前を一度だけ
  //   ・自分のは、左に細い線を引くだけで分ける(吹き出しにしない ──
  //     長い文が入るし、和文は左揃えのほうが読める)
  //   ・時刻は端に、薄く
  import { renderEmojis } from '$lib/emoji';
  import { phrase } from '$lib/phrase';
  import Avatar from './Avatar.svelte';
  import Twemoji from './Twemoji.svelte';
  import ReactionPicker from './ReactionPicker.svelte';
  import * as api from '$lib/api';
  import { toggled, willAdd } from '$lib/reactions';
  import type { Reaction, Status } from '$lib/api';
  import { splitLeadingMentions } from '$lib/preview';
  import { t, locale, type Locale, type TranslationKey } from '$lib/i18n';

  let {
    status,
    mine = false,
    grouped = false
  }: { status: Status; mine?: boolean; grouped?: boolean } = $props();

  let name = $derived(status.account.display_name || status.account.username);

  // 宛名は本文から外して、下に小さく置く ── 消すのではなく、どける。
  // (サーバの `mentions` はまだ空を返すので、本文の h-card から拾う)
  let split = $derived(splitLeadingMentions(status.content));

  // ── 絵文字で、そっと返す ─────────────────────────────────────────
  //
  // 返事を書くほどではないけれど、無言でもない ── そのあいだの返し方。
  // 「読んだよ」「うれしい」を一文字で置ける。既読の印を機械が付けるのと
  // 違って、これは**その人が押した**もの。押さない自由もある。
  //
  // 押した瞬間に手元を書き換えて、返事は後から待つ。落ちたら、そっと戻す
  // ── 失敗を叫ばない(その一押しは、そこまで大事な用ではない)。
  let reactions = $state<Reaction[]>([]);
  let pickerOpen = $state(false);

  // 拾い直しで status ごと入れ替わることがあるので、そのたびに合わせ直す。
  $effect(() => {
    reactions = status.reactions ?? [];
  });

  async function toggle(emoji: string) {
    const snapshot = reactions;
    const adding = willAdd(reactions, emoji);
    reactions = toggled(reactions, emoji);
    try {
      await (adding ? api.react(status.id, emoji) : api.unreact(status.id, emoji));
    } catch {
      reactions = snapshot;
    }
  }

  function shortTime(
    iso: string,
    tr: (key: TranslationKey, params?: Record<string, string | number>) => string,
    loc: Locale
  ): string {
    try {
      const d = new Date(iso);
      const diff = (Date.now() - d.getTime()) / 1000;
      if (diff < 60) return tr('status.now');
      if (diff < 3600) return tr('status.minutesAgo', { n: Math.floor(diff / 60) });
      if (diff < 86_400) return tr('status.hoursAgo', { n: Math.floor(diff / 3600) });
      if (diff < 86_400 * 7) return tr('status.daysAgo', { n: Math.floor(diff / 86_400) });
      return d.toLocaleDateString(loc === 'ko' ? 'ko-KR' : 'ja-JP');
    } catch {
      return '';
    }
  }
</script>

<article class="dm" class:mine class:grouped>
  {#if !grouped}
    <header class="dm-head">
      <Avatar class="avatar avatar-sm" src={status.account.avatar} {name} />
      <span class="dm-name">{@html renderEmojis(phrase(name), status.account.emojis)}</span>
      <a class="dm-when" href={`/@${status.account.acct}/${status.id}`}>
        {shortTime(status.created_at, $t, $locale)}
      </a>
    </header>
  {/if}

  {#if status.spoiler_text}
    <details>
      <summary>{status.spoiler_text}</summary>
      <div class="dm-body">{@html split.body}</div>
    </details>
  {:else}
    <div class="dm-body">{@html split.body}</div>
  {/if}

  {#if split.handles.length > 0}
    <p class="dm-to">{$t('messages.mentioned', { who: split.handles.map((h) => `@${h}`).join(' ') })}</p>
  {/if}

  <!-- 付いている絵文字と、足す口。**足す口は、押されるまで出ない** ──
       一通ごとに ＋ が並ぶと、会話が操作の列に見える。触れたとき(hover)か、
       tab で来たときだけ、そっと現れる。指の画面では常に出す(hover が
       無いので、出ないと辿り着けない)。 -->
  <div class="dm-reactions">
    {#each reactions as r (r.name)}
      <button type="button" class="reaction-chip" class:me={r.me} title={r.name} onclick={() => toggle(r.name)}>
        {#if r.url}
          <img class="emoji" src={r.url} alt={r.name} loading="lazy" />
        {:else}
          <span class="emoji"><Twemoji emoji={r.name} /></span>
        {/if}
        {#if r.count > 1}<span class="count">{r.count}</span>{/if}
      </button>
    {/each}

    <button
      type="button"
      class="reaction-add"
      aria-haspopup="dialog"
      aria-expanded={pickerOpen}
      title={$t('reaction.pick')}
      aria-label={$t('reaction.pick')}
      onclick={() => (pickerOpen = !pickerOpen)}
    >
      ＋
    </button>
  </div>

  {#if pickerOpen}
    <ReactionPicker
      onpick={(e) => void toggle(e)}
      onclose={() => (pickerOpen = false)}
    />
  {/if}

  {#if status.media_attachments?.length}
    <ul class="dm-media">
      {#each status.media_attachments as m (m.id)}
        <li>
          {#if m.preview_url || m.url}
            <a href={m.url} target="_blank" rel="noopener noreferrer">
              <img src={m.preview_url || m.url} alt={m.description ?? ''} loading="lazy" />
            </a>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</article>

<style>
  .dm {
    padding: var(--space-2) 0 var(--space-2) var(--space-3);
    /* 自分のぶんだけ、左に細い線。吹き出しにはしない ── 長い文も入るし、
       和文は左揃えのほうが読める。色ではなく形で分けるので、色が見え
       にくい人にも同じように分かる。 */
    border-left: 2px solid transparent;
  }

  .dm.mine {
    border-left-color: var(--color-border-strong);
  }

  /* 続けて喋ったぶんは、名前を出さないので上を詰める。 */
  .dm.grouped {
    padding-top: 0;
  }

  .dm-head {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    margin-bottom: var(--space-1);
  }

  .dm-name {
    font-weight: 700;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .dm-when {
    margin-left: auto;
    flex: none;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
    text-decoration: none;
  }

  .dm-when:hover {
    text-decoration: underline;
  }

  /* 字下げはしない。アバターぶん(44px)下げると続きには見えるけれど、
     そのぶん本文が狭くなる ── スマホでは、その 44px のほうが要る。
     誰が言ったかは、名前と左の線がもう言っているので、揃えなくても
     迷わない。 */
  .dm-body {
    overflow-wrap: anywhere;
  }

  /* 宛名。本文ではないので、字を小さく薄く ── 見えるけれど、読まなくていい。 */
  .dm-to {
    margin: var(--space-1) 0 0;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }

  /* ── 絵文字の返し ───────────────────────────────────────────────── */

  .dm-reactions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-1);
    margin-top: var(--space-1);
  }

  .reaction-chip {
    font: inherit;
    font-size: var(--text-sm);
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    padding: 2px var(--space-2);
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: 999px;
    color: var(--color-text-muted);
    cursor: pointer;
  }

  /* 自分が押したものは、罫線を濃く。色ではなく濃さで言う ── 色が見え
     にくい人にも、同じだけ伝わるように。 */
  .reaction-chip.me {
    border-color: var(--color-text);
    color: var(--color-text);
  }

  .reaction-chip :global(.emoji) {
    display: inline-flex;
    width: 1.15em;
    height: 1.15em;
  }

  /* 足す口。ふだんは見えない ── 会話は、操作の列ではないので。
     触れたとき・tab で来たとき・すでに何か付いているときだけ出す。 */
  .reaction-add {
    font: inherit;
    font-size: var(--text-sm);
    line-height: 1;
    padding: 3px var(--space-2);
    background: transparent;
    border: 1px dashed var(--color-border);
    border-radius: 999px;
    color: var(--color-text-muted);
    cursor: pointer;
    opacity: 0;
  }

  .dm:hover .reaction-add,
  .reaction-add:focus-visible,
  .dm-reactions:has(.reaction-chip) .reaction-add {
    opacity: 1;
  }

  /* 指で触る画面には hover が無い。出ないままだと、辿り着けない。 */
  @media (pointer: coarse) {
    .reaction-add {
      opacity: 1;
    }
  }

  .dm-media {
    list-style: none;
    margin: var(--space-2) 0 0;
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
  }

  .dm-media img {
    max-width: 12rem;
    border-radius: var(--radius-sm);
  }
</style>
