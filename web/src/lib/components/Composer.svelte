<script lang="ts">
  import { tick, untrack } from 'svelte';
  import {
    postStatus,
    uploadMedia,
    type Account,
    type MediaAttachment,
    type Status,
    type Visibility
  } from '#lib/api.js';
  import { clearToken } from '#lib/auth.js';
  import {
    loadComposeDraft,
    saveComposeDraft,
    clearComposeDraft,
    reconcileComposeDraft,
    loadDmDraft,
    saveDmDraft,
    clearDmDraft
  } from '#lib/compose-draft.js';
  import { goto } from '$app/navigation';
  import { t } from '#lib/i18n.js';
  import { createAutocomplete, type AutocompleteItem } from '#lib/autocomplete.svelte.js';
  import AutocompleteDropdown from './AutocompleteDropdown.svelte';
  import Avatar from './Avatar.svelte';
  import NavIcon from './NavIcon.svelte';
  import QuoteCard from './QuoteCard.svelte';
  import EmojiPicker from './EmojiPicker.svelte';
  import Twemoji from './Twemoji.svelte';

  let {
    replyTo = null,
    // 引用する投稿。立てると、その投稿を引用したノートになる。
    // 返信と同じく一時的な文脈なので、下書きには覚えさせない。
    quoteOf = null,
    // 返信のとき、返信先 acct をテキスト先頭に入れたい場合に使う
    // (Mastodon 互換クライアントは「@user@host 」を頭につけて出す慣習)
    prefillMention = false,
    // グループ DM への返信で、参加者みんなを宛先にしたいときに使う。
    // DM の宛先は本文の @ 言及から決まるので、最後の発言者一人だけを
    // 入れると会話が黙って一対一に縮む。全員の acct を渡せばグループの
    // まま返せる。指定があるときは prefillMention より優先する。
    prefillRecipients = null,
    // DM のスレッドに置くときの会話 id。渡すと DM モードになる:
    //   ・可視性を direct に固定して、選ぶ口を出さない。いまは replyTo の
    //     可視性から偶然 direct になっているだけで、人の手で public に
    //     切り替えられる。DM のスレッドで公開に化けた一通は取り返せない
    //   ・折りたたみ・注意書き・予約を畳む(DM では使わない)
    //   ・入力が伸びる。長い文を書く場所なので
    //   ・書きかけを、この会話の名前で覚える
    dmConversationId = null,
    // 「書く」の面に置くとき。ほかに何も無い一枚なので、枠で囲わず、
    // 入力を大きく取る ── 面そのものが composer なので、面の中でもう一度
    // 箱を描く必要がない。
    page = false,
    // 流れの外に、画面の底へ固定して置くとき(Clips)。
    fixed = false,
    // 入力欄の根(form)を親へ渡す。親が高さを測るときに使う。
    root = $bindable(null),
    // 添付ファイルの入力ダイアログに渡す accept。既定は画像だけ(いまの
    // 全画面の実際の挙動と同じ) ── Clips だけ、ここを広げて任意のファイルを
    // 通す。サーバ側はもう MIME で弾いていない(image/video/audio 以外は
    // type: "unknown" で普通に受ける)ので、ここは入口の絞りだけの話。
    accept = 'image/*',
    onposted,
    oncancel
  }: {
    replyTo?: Status | null;
    quoteOf?: Status | null;
    prefillMention?: boolean;
    prefillRecipients?: string[] | null;
    dmConversationId?: string | null;
    page?: boolean;
    fixed?: boolean;
    root?: HTMLElement | null;
    accept?: string;
    onposted?: (s: Status) => void;
    oncancel?: () => void;
  } = $props();

  // 書きかけの下書きは、トップの新規ノートだけ覚える。返信のときは
  // 覚えない(replyTo があるとここは null)。初回マウントで一度だけ
  // 拾う ─ untrack の中なので、あとのユーザ入力では読み直さない。
  const restored = untrack(() => (replyTo || quoteOf ? null : loadComposeDraft()));

  // DM モードかどうか。以下ぜんぶ、この一つの値から決まる。
  const dm = $derived(!!dmConversationId);

  // DM の書きかけは会話ごとに、この端末だけで覚える(compose-draft.ts)。
  // 覚えていたものがあれば、宛先の @ より優先して戻す ─ 書きかけには
  // すでに @ が入っている。
  const restoredDm = untrack(() => (dmConversationId ? loadDmDraft(dmConversationId) : ''));

  // 初期値だけ prop を見たい(あとはユーザが書き換える)ので untrack で
  // 拾う。これがないと state_referenced_locally の warning が出る。
  let text = $state(
    untrack(() => restoredDm || restored?.text || initialMentionText())
  );

  // 宛先の @ 言及。DM の宛先は本文の言及で決まる(サーバの契約)ので、
  // 必ずどこかに要る。
  function mentionHandles(): string[] {
    if (prefillRecipients && prefillRecipients.length > 0) return prefillRecipients;
    if (prefillMention && replyTo) return [replyTo.account.acct];
    return [];
  }

  // **DM では、入力欄に入れない。** 書き出しに相手の名前が居座ると、
  // その手前から書けないし、消すと dm_no_recipients で断られる ── 消せない
  // ものを本文に置くのは、書き手に断りなく席を取っているのと同じ。
  // 送るときに、あたまへ回す。
  function initialMentionText(): string {
    if (dm) return '';
    const handles = mentionHandles();
    return handles.length > 0 ? handles.map((h) => `@${h}`).join(' ') + ' ' : '';
  }

  // 送る本文。DM のときだけ、宛先をあたまに足す。
  //
  // 先頭が de facto ── 連合の向こうの実装も、人の目も、そこを宛名だと
  // 知っている。**置く場所は慣習に合わせて、見え方はこちらで引く。**
  // 読む側では `splitLeadingMentions` が本文から外して、下に小さく添える。
  function bodyToSend(): string {
    if (!dm) return text;
    const handles = mentionHandles().filter((h) => !text.includes(`@${h}`));
    return handles.length > 0 ? `${handles.map((h) => `@${h}`).join(' ')} ${text}` : text;
  }
  let spoiler = $state(untrack(() => restored?.spoiler ?? ''));
  let useSpoiler = $state(untrack(() => restored?.useSpoiler ?? false));
  let sensitive = $state(untrack(() => restored?.sensitive ?? false));
  // DM では動かさない。選ぶ口も出さないので、ここが唯一の決まる場所。
  let visibility = $state<Visibility>(
    untrack(() => (dm ? 'direct' : (restored?.visibility ?? replyTo?.visibility ?? 'public')))
  );
  let media = $state<MediaAttachment[]>([]);
  let uploading = $state(false);
  let posting = $state(false);
  let error = $state<string | null>(null);
  let fileInput: HTMLInputElement | undefined = $state();
  let emojiPickerOpen = $state(false);

  // カーソルのある場所に入れる。前後が語のつながりなら、:shortcode: が
  // 字とくっつかないよう空白を一つ挟む。入れたあとのカーソルは、絵文字の後ろ。
  async function insertEmoji(value: string) {
    emojiPickerOpen = false;
    const el = box;
    if (!el) {
      text = `${text}${value} `;
      return;
    }
    const start = el.selectionStart ?? text.length;
    const end = el.selectionEnd ?? start;
    const before = text.slice(0, start);
    const after = text.slice(end);
    const lead = before && !/\s$/.test(before) ? ' ' : '';
    const trail = after && !/^\s/.test(after) ? ' ' : '';
    const inserted = lead + value + trail;
    text = before + inserted + after;
    const caret = (before + inserted).length;
    await tick();
    el.focus();
    el.setSelectionRange(caret, caret);
  }

  // ── メンション・絵文字の自動補完 ─────────────────────────────────
  //
  // 打っている途中の `@語` または `:絵文字` に効く。**選ぶまで本文は変わらない** ──
  // 勝手に確定させると、書いた覚えのない名前や絵文字が文に入る。
  let box: HTMLTextAreaElement | undefined = $state();
  const autocomplete = createAutocomplete();

  function lookForAutocomplete() {
    if (!box) return;
    autocomplete.look(box.value, box.selectionStart ?? box.value.length);
  }

  function pickAutocomplete(item: AutocompleteItem) {
    if (!box) return;
    const r = autocomplete.pick(text, autocomplete.items.indexOf(item));
    if (r) {
      text = r.text;
      autocomplete.close();
      // カーソルを置き直す。DOM が更新されてから。
      queueMicrotask(() => box?.setSelectionRange(r.caret, r.caret));
      box.focus();
    }
  }

  // 候補が開いているあいだだけ、上下と Enter を借りる。開いていなければ
  // DM は Enter で送り、それ以外は改行のまま。
  //
  // DM を Enter で送るのは、短い一言を続けて投げる場所だから。改行が
  // 要るときは Shift+Enter ── LINE と同じ約束。**DM 以外では変えない**:
  // ふつうの投稿は長く書くことがあるので、Enter が送信だと事故になる。
  //
  // **ただし、指で触る画面では Enter は改行のまま。** スマホのキーボードに
  // Shift は無いので、Enter が送信だと改行の入れようが無くなる ── 二行書き
  // たいだけの人が、書けなくなる。送るのは「送る」を押して。
  const sendsOnEnter = () =>
    typeof window === 'undefined' || !window.matchMedia('(pointer: coarse)').matches;

  function onComposerKey(e: KeyboardEvent) {
    if (e.isComposing) return;

    if (!autocomplete.open) {
      if (dm && sendsOnEnter() && e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        if (canPost) void submit();
      }
      return;
    }
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      autocomplete.move(1);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      autocomplete.move(-1);
    } else if (e.key === 'Enter' || e.key === 'Tab') {
      const item = autocomplete.items[autocomplete.active];
      if (item) {
        e.preventDefault();
        pickAutocomplete(item);
      }
    } else if (e.key === 'Escape') {
      e.preventDefault();
      autocomplete.close();
    }
  }

  // 予約投稿。チェックを入れたときだけ日時を見る。返信では出さない
  // (返信を寝かせる場面はまずない)。下書きには含めない ─ 時刻は
  // その場で決めるものなので、覚えて復元すると過去になっている。
  let useSchedule = $state(false);
  let scheduleAt = $state('');

  let visLabels: Record<Visibility, string> = $derived({
    public: $t('compose.visPublic'),
    unlisted: $t('compose.visUnlisted'),
    private: $t('compose.visPrivate'),
    direct: $t('compose.visDirect')
  });

  let canPost = $derived(
    !posting &&
      !uploading &&
      (text.trim().length > 0 || media.length > 0)
  );

  // 復元したことを、一言だけそっと伝える。捨てるか、送ると消える。
  let showRestored = $state(!!restored);

  // サーバとの突き合わせが済むまでは、空の下書きで写しを消さない
  // (開いた直後の空フォームが、別端末の下書きを先に消してしまう競合を
  // 防ぐ)。済んだら true になり、以後は save/clear がふつうに動く。
  let reconciled = $state(false);

  // 書きながら、すこし手が止まったら覚える。トップの新規ノート専用。
  // 中身が空っぽになったら、覚えていたものは消す(空の下書きは残さない)。
  // DM の書きかけ。会話ごとに、手が止まったら覚える。空になったら消す。
  // サーバ同期は無いので、上の reconcile とは関わらない。
  $effect(() => {
    if (!dmConversationId) return;
    const body = text;
    const id = setTimeout(() => {
      if (body.trim() === '') clearDmDraft(dmConversationId);
      else saveDmDraft(dmConversationId, body);
    }, 800);
    return () => clearTimeout(id);
  });

  $effect(() => {
    if (replyTo) return;
    const snapshot = { text, spoiler, useSpoiler, sensitive, visibility };
    const empty = snapshot.text.trim() === '' && snapshot.spoiler.trim() === '';
    // まだ突き合わせ前の空フォームは、何もしない(写しを消さない)。
    if (empty && !reconciled) return;
    const id = setTimeout(() => {
      if (empty) {
        clearComposeDraft();
      } else {
        saveComposeDraft(snapshot);
      }
    }, 800);
    return () => clearTimeout(id);
  });

  // 開いたとき、ローカルとサーバの下書きを静かに突き合わせる。トップの
  // 新規ノート専用。ローカルが正本なので、まだ何も書いていないときだけ
  // サーバの写し(別端末の続き)を迎え入れる ─ 書きかけを上書きしない。
  // untrack で、ここで読む値が依存に乗らないようにする(初回だけ動かす)。
  $effect(() => {
    if (replyTo) {
      reconciled = true;
      return;
    }
    void reconcileComposeDraft()
      .then((d) => {
        untrack(() => {
          if (!d) return;
          if (text.trim() !== '' || spoiler.trim() !== '') return;
          text = d.text;
          spoiler = d.spoiler;
          useSpoiler = d.useSpoiler;
          sensitive = d.sensitive;
          visibility = d.visibility;
          showRestored = !!d.text || !!d.spoiler;
        });
      })
      .finally(() => {
        reconciled = true;
      });
  });

  // 「捨てる」。書いたものを空に戻して、覚えていた下書きも消す。
  function discard() {
    text = '';
    spoiler = '';
    useSpoiler = false;
    sensitive = false;
    showRestored = false;
    clearComposeDraft();
  }

  async function onFiles(ev: Event) {
    const input = ev.currentTarget as HTMLInputElement;
    const files = input.files ? Array.from(input.files) : [];
    if (files.length === 0) return;
    uploading = true;
    error = null;
    try {
      for (const f of files) {
        const m = await uploadMedia(f);
        media = [...media, m];
      }
    } catch (e) {
      error = handleErr(e, $t('compose.uploadFailed'));
    } finally {
      uploading = false;
      input.value = '';
    }
  }

  function removeMedia(id: string) {
    media = media.filter((m) => m.id !== id);
  }

  async function submit() {
    if (!canPost) return;
    // 予約のチェックは入っているのに、日時が空。送らずに、そっと促す。
    const scheduledAt = useSchedule && scheduleAt ? new Date(scheduleAt).toISOString() : null;
    if (useSchedule && !scheduledAt) {
      error = $t('compose.scheduleNeedsTime');
      return;
    }
    posting = true;
    error = null;
    try {
      const s = await postStatus({
        status: bodyToSend(),
        spoiler_text: useSpoiler ? spoiler : undefined,
        sensitive: sensitive || (useSpoiler && !!spoiler) || undefined,
        visibility,
        in_reply_to_id: replyTo?.id ?? null,
        quote_id: quoteOf?.id ?? null,
        media_ids: media.map((m) => m.id),
        scheduled_at: scheduledAt
      });
      // 送れた。フォームを空に戻して、覚えていた下書きも消す。
      if (dmConversationId) clearDmDraft(dmConversationId);
      text = '';
      spoiler = '';
      useSpoiler = false;
      sensitive = false;
      useSchedule = false;
      scheduleAt = '';
      media = [];
      showRestored = false;
      clearComposeDraft();
      // 予約のときは、まだタイムラインには出ない。出ていないものを
      // 出すと嘘になるので、親には渡さない。
      if (scheduledAt) return;
      onposted?.(s);
    } catch (e) {
      error = handleErr(e, $t('compose.postFailed'));
    } finally {
      posting = false;
    }
  }

  // 送る口の言葉。絵の印にしたぶん、いまどの状態かは title と読み上げが
  // 引き受ける ── 「送信中…」が見えなくなっただけで、無くなってはいない。
  const sendLabel = () =>
    posting ? $t('common.sending') : uploading ? $t('compose.uploading') : $t('compose.submit');

  function handleErr(e: unknown, fallback: string): string {
    const msg = e instanceof Error ? e.message : '';
    if (msg === 'unauthorized') {
      clearToken();
      void goto('/');
      return $t('compose.reauth');
    }
    return fallback;
  }
</script>

<form
  bind:this={root}
  class="composer"
  class:composer-page={page}
  class:fixed-dock={fixed}
  class:composer-dm={dm}
  onsubmit={(e) => {
    e.preventDefault();
    void submit();
  }}
>
  {#if quoteOf}
    <p class="composer-reply">
      <span>{$t('compose.quoting', { acct: quoteOf.account.acct })}</span>
      {#if oncancel}
        <button type="button" class="chip" onclick={() => oncancel?.()}
          >{$t('compose.cancel')}</button
        >
      {/if}
    </p>
    <QuoteCard status={quoteOf} />
  {:else if replyTo && oncancel}
    <p class="composer-reply">
      <span>{$t('compose.replyTo', { acct: replyTo.account.acct })}</span>
      <button type="button" class="chip" onclick={() => oncancel?.()}>{$t('compose.cancel')}</button>
    </p>
  {:else if showRestored}
    <p class="composer-reply">
      <span>{$t('compose.draftRestored')}</span>
      <button type="button" class="chip" onclick={discard}>{$t('compose.discardDraft')}</button>
    </p>
  {/if}

  {#if useSpoiler}
    <label class="stack-tight">
      <span>{$t('compose.spoilerLabel')}</span>
      <input
        type="text"
        bind:value={spoiler}
        placeholder={$t('compose.spoilerPlaceholder')}
        maxlength="80"
      />
    </label>
  {/if}

  <!-- 本文の欄そのものは一つ。DM ではそれを一行の並びに置く。 -->
  {#snippet bodyField()}
    <textarea
      bind:this={box}
      class:grows={dm || page}
      bind:value={text}
      rows={dm ? 1 : 3}
      placeholder={replyTo ? $t('compose.placeholderReply') : $t('compose.placeholderNew')}
      onkeydown={onComposerKey}
      oninput={lookForAutocomplete}
      onclick={lookForAutocomplete}
      onblur={() => setTimeout(() => autocomplete.close(), 120)}
    ></textarea>
  {/snippet}

  {#if dm}
    <!-- LINE の並び ── 画像は本文の左、送るは右、本文は基本ひと行。
         語を絵に置きかえたので、語のほうは aria-label と title に残す。
         見えなくなっただけで、無くなってはいない。 -->
    <div class="composer-line">
      <label class="icon-btn" title={$t('compose.addImage')} aria-label={$t('compose.addImage')}>
        <NavIcon name="image" />
        <input
          bind:this={fileInput}
          type="file"
          {accept}
          multiple
          onchange={onFiles}
          style="display: none;"
        />
      </label>

      <label class="composer-line-field">
        <span class="visually-hidden">{$t('compose.bodyLabel')}</span>
        {@render bodyField()}
      </label>

      <button
        type="submit"
        class="icon-btn"
        disabled={!canPost}
        title={sendLabel()}
        aria-label={sendLabel()}
      >
        <NavIcon name="send" />
      </button>
    </div>
  {:else}
    <label class="stack-tight">
      <span class="visually-hidden">{$t('compose.bodyLabel')}</span>
      {@render bodyField()}
    </label>
  {/if}

  <!-- 打っている途中の @語 や :絵文字 の候補。開いていないときは、何も無い。
       選ぶまで本文は変わらない ── 勝手に確定させない。 -->
  {#if autocomplete.open}
    <AutocompleteDropdown
      items={autocomplete.items}
      active={autocomplete.active}
      above={dm}
      onpick={pickAutocomplete}
    />
  {/if}

  {#if useSchedule}
    <label class="stack-tight">
      <span>{$t('compose.scheduleLabel')}</span>
      <input type="datetime-local" bind:value={scheduleAt} />
      <small class="composer-hint">{$t('compose.scheduleHint')}</small>
    </label>
  {/if}

  {#if media.length > 0}
    <ul class="composer-media">
      {#each media as m (m.id)}
        <li>
          {#if m.preview_url || m.url}
            <img src={m.preview_url || m.url} alt={m.description ?? ''} />
          {/if}
          <button type="button" class="chip" onclick={() => removeMedia(m.id)}>
            {$t('compose.removeMedia')}
          </button>
        </li>
      {/each}
    </ul>
  {/if}

  <!-- ふだん使わない三つは、畳んでおく。ここは短い一言を書く場所で、
       折りたたみも、見せ注意も、時間指定も、たまにしか要らない。表に
       出しておくと、六つ並んだ操作のほうが本文より大きくなる。
       DM では畳む以前に出さない(上と同じ理由)。 -->
  {#if !dm}
    <details class="composer-more">
      <summary>{$t('compose.more')}</summary>
      <div class="composer-more-row">
        <label class="stack-tight">
          <input type="checkbox" bind:checked={useSpoiler} />
          <span>{$t('compose.fold')}</span>
        </label>

        <label class="stack-tight">
          <input type="checkbox" bind:checked={sensitive} />
          <span>{$t('compose.sensitive')}</span>
        </label>

        <label class="stack-tight">
          <input type="checkbox" bind:checked={useSchedule} />
          <span>{$t('compose.schedule')}</span>
        </label>
      </div>
    </details>
  {/if}

  <!-- DM では、この行そのものが要らない ── 画像も送るも、上の一行に居る。
       可視性の select は出さないだけでなく、出してはいけない ── 手が滑って
       公開に切り替わった一通は取り返せない。 -->
  {#if !dm}
    <div class="composer-row">
      <label class="chip">
        {$t('compose.addImage')}
        <input
          bind:this={fileInput}
          type="file"
          {accept}
          multiple
          onchange={onFiles}
          style="display: none;"
        />
      </label>

      <div class="picker-container">
        <button
          type="button"
          class="chip"
          onclick={() => (emojiPickerOpen = !emojiPickerOpen)}
          aria-haspopup="dialog"
        >
          <Twemoji emoji="😃" /> {$t('reaction.pick')}
        </button>
        {#if emojiPickerOpen}
          <div class="composer-picker-anchor">
            <EmojiPicker onpick={insertEmoji} onclose={() => (emojiPickerOpen = false)} />
          </div>
        {/if}
      </div>

      <label class="stack-tight">
        <span class="visually-hidden">{$t('compose.visLabel')}</span>
        <select bind:value={visibility}>
          {#each Object.entries(visLabels) as [v, label] (v)}
            <option value={v}>{label}</option>
          {/each}
        </select>
      </label>

      <button type="submit" class="btn px-6 py-2" disabled={!canPost}>
        {sendLabel()}
      </button>
    </div>
  {/if}

  {#if error}
    <p class="error">{error}</p>
  {/if}
</form>

<style>
  .picker-container {
    position: relative;
    display: inline-flex;
  }

  .composer-picker-anchor {
    position: absolute;
    bottom: 100%;
    left: 0;
    margin-bottom: 0.25rem;
    z-index: 50;
  }

  .composer {
    max-width: var(--measure);
    margin: 0 auto var(--space-6);
    padding: var(--space-4);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  /* DM の入力。長い文を書く場所なので、書いたぶんだけ伸びる。上限は置かない
     ── 途中でスクロールに切り替わると、書いている場所を見失う。
     field-sizing が無いブラウザでは rows のまま(4 行)で、壊れはしない。 */
  .composer textarea.grows {
    field-sizing: content;
    /* 短い一言を続けて投げる場所なので、二行から。長く書けば伸びる。 */
    min-height: calc(2lh + var(--space-4));
  }

  /* ── メッセージの返信箱 ─────────────────────────────────────────────
     会話の面では、返信箱は下に貼りつく。流れの末尾に置くと、長いやりとりでは
     毎回いちばん下まで漕がないと返せない ── 話しかける口が、遠い。
     (スマホの SNS がどれも下に固定しているのは、そういう理由。) */
  .composer-dm {
    position: sticky;
    bottom: 0;
    z-index: 10;
    margin-bottom: 0;
    background: var(--color-bg);
    border: 0;
    border-top: 1px solid var(--color-border);
    border-radius: 0;
    padding: var(--space-3) var(--space-4);
    padding-bottom: max(var(--space-3), env(safe-area-inset-bottom, 0px));
  }

  /* スマホでは下に親指の帯があるので、その上に貼る。帯が縁の余白(safe-area)を
     もう持っているから、ここでは重ねて取らない。 */
  @media (max-width: 40rem) {
    :global(body.has-bottom-nav) .composer-dm {
      bottom: var(--bottom-nav-h);
      padding-bottom: var(--space-3);
    }

    /* 返信箱は、画面の端から端まで。.wrap の左右 gutter を負の margin で
       いったん外に出て、カプセルに幅を返す ── 打つところは広いほうがいい。
       罫線も端まで通るので、下の帯として素直に見える。 */
    .composer-dm {
      max-width: none;
      margin-inline: calc(var(--space-4) * -1);
      padding-inline: var(--space-2);
    }
  }

  /* 伸びるのは、画面の半分まで。それを超えたら中で漕ぐ ── 長い一通を書いて
     いるあいだに、宛てている会話がぜんぶ画面の外へ出てしまわないように。
     (「書く」の面には上限を置かない。あちらは会話を見ながらではないので。) */
  .composer-dm textarea.grows {
    max-height: 40vh;
    overflow-y: auto;
    /* 自分で伸びるので、つまんで伸ばす取っ手は要らない。 */
    resize: none;
    /* 基本はひと行。書いたぶんだけ、そこから伸びる。 */
    min-height: calc(1lh + var(--space-4));
  }

  /* 画像・本文・送る を、ひと並びに。左に画像、右に送る ── 本文の両脇に、
     すること二つ。行が一つ減るぶんは、そのまま会話の見えるところに返る。
     囲うのはこのカプセル一つだけ。中の本文欄は枠を持たない ── 枠の中に枠を
     描くと輪郭が二重になる(「塗りと枠は片方だけ」の、入れ子版)。
     伸びても端は丸いままなので、半径は高さの半分で置く。 */
  .composer-line {
    display: flex;
    align-items: flex-end;
    gap: var(--space-1);
    padding: 2px;
    border: 1px solid var(--color-control);
    border-radius: 23px;
    background: var(--color-surface);
  }

  /* 中では、枠も背景も持たない。カプセルが面で、これはその中の文。 */
  .composer-line-field textarea {
    border: 0;
    background: transparent;
    border-radius: 0;
    padding-inline: var(--space-2);
  }

  .composer-line-field textarea:focus {
    outline: none;
  }

  /* カプセルが focus を受け止める ── 中の一つひとつではなく、この一つが
     光る。どこを触っているかは、囲いの側で言う。 */
  .composer-line:focus-within {
    border-color: var(--color-text);
  }

  /* 中の印は、丸い縁を持たない。カプセルの中で丸が三つ並ぶと、囲いが
     どれなのか分からなくなる。 */
  .composer-line .icon-btn {
    border-color: transparent;
  }

  .composer-line-field {
    flex: 1;
    min-width: 0;
    margin: 0;
  }

  /* textarea はインライン要素なので、下に行の余り(descender のぶん)が残る。
     そのぶんだけ入力欄が両脇のボタンより浮いて見えていた。block にして、
     下端をそろえる。 */
  .composer-line-field textarea {
    display: block;
  }

  /* カプセルの内側では、いちばん低いところ(1行)がボタンと同じ高さになる
     ように。上下の余白はカプセルの padding が持つ。 */
  .composer-dm .composer-line textarea.grows {
    min-height: 40px;
    padding-block: var(--space-2);
  }

  /* 絵の印だけのボタン。丸くて、指で押せて、押せないときは薄い。
     語は aria-label と title に残してある(読み上げと hover には届く)。 */
  .icon-btn {
    flex: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 44px;
    height: 44px;
    padding: 0;
    background: transparent;
    border: 1px solid var(--color-control);
    border-radius: 999px;
    color: var(--color-text-muted);
    cursor: pointer;
    transition:
      color 0.1s ease,
      border-color 0.1s ease;
  }

  .icon-btn:hover:not(:disabled) {
    color: var(--color-text);
    border-color: var(--color-text);
  }

  /* 「書く」の面。ほかに何も無い一枚なので、枠で囲わない ── 面そのものが
     composer なのに、その中でもう一度箱を描くと、輪郭が二重になる。
     (図解の頁が言う「塗りと枠は片方だけ」の、入れ子版。) */
  .composer-page {
    border: 0;
    padding: 0;
    margin-bottom: var(--space-6);
  }

  /* 「書く」は短い一言のための場所。白紙を大きく開けると「たくさん書け」に
     見えるので、三行から始めて、書いたぶんだけ伸ばす。 */
  .composer-page textarea.grows {
    min-height: calc(3lh + var(--space-4));
  }

  /* 畳んである「ほかの設定」。開くまで、何も主張しない。 */
  .composer-more > summary {
    font-size: var(--text-sm);
    color: var(--color-text-muted);
    cursor: pointer;
  }

  .composer-more-row {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2) var(--space-4);
    margin-top: var(--space-2);
  }

  .composer-more-row label.stack-tight {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    font-size: var(--text-sm);
    color: var(--color-text-muted);
    margin: 0;
  }

  .composer-reply {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: var(--space-3);
    margin: 0;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }

  .composer-hint {
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }

  .composer-row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-3);
  }

  .composer-row label.stack-tight {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    font-size: var(--text-sm);
    color: var(--color-text-muted);
    margin: 0;
  }

  .composer-row > button[type='submit'] {
    margin-left: auto;
  }

  .composer-media {
    list-style: none;
    margin: 0;
    padding: 0;
    display: grid;
    gap: var(--space-2);
    grid-template-columns: repeat(auto-fill, minmax(10rem, 1fr));
  }

  .composer-media li {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }

  .composer-media img {
    width: 100%;
    border-radius: var(--radius-sm);
    border: 1px solid var(--color-border);
    display: block;
  }

  /* 「書く」を画面の底に固定する。Clips は流れの外に置きたいので、親から
     fixed で頼む(親が :global で触るのをやめる)。 */
  .composer-dm.fixed-dock {
    position: fixed;
    left: 0;
    right: 0;
  }

  /* 固定したときは、親の .wrap の gutter を外へ抜ける必要がない(基準が
     画面になる)。ここで負の margin を重ねると、画面の両側へはみ出す。 */
  @media (max-width: 40rem) {
    .composer-dm.fixed-dock {
      margin-inline: 0;
    }
  }
</style>
