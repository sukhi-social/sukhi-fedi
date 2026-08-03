<script lang="ts">
  import { untrack } from 'svelte';
  import {
    postStatus,
    uploadMedia,
    type MediaAttachment,
    type Status,
    type Visibility
  } from '$lib/api';
  import { clearToken } from '$lib/auth';
  import {
    loadComposeDraft,
    saveComposeDraft,
    clearComposeDraft,
    reconcileComposeDraft,
    loadDmDraft,
    saveDmDraft,
    clearDmDraft
  } from '$lib/compose-draft';
  import { goto } from '$app/navigation';
  import { t } from '$lib/i18n';
  import QuoteCard from './QuoteCard.svelte';

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
    onposted,
    oncancel
  }: {
    replyTo?: Status | null;
    quoteOf?: Status | null;
    prefillMention?: boolean;
    prefillRecipients?: string[] | null;
    dmConversationId?: string | null;
    page?: boolean;
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

  // 返信の頭につける @ 言及。グループの宛先が渡されていればそれを全部、
  // なければ(prefillMention のとき)返信先一人だけ。
  function initialMentionText(): string {
    const handles =
      prefillRecipients && prefillRecipients.length > 0
        ? prefillRecipients
        : prefillMention && replyTo
          ? [replyTo.account.acct]
          : [];
    return handles.length > 0 ? handles.map((h) => `@${h}`).join(' ') + ' ' : '';
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
        status: text,
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
  class="composer"
  class:composer-page={page}
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

  <label class="stack-tight">
    <span class="visually-hidden">{$t('compose.bodyLabel')}</span>
    <textarea
      class:grows={dm || page}
      bind:value={text}
      rows={dm ? 4 : page ? 8 : replyTo ? 3 : 4}
      placeholder={replyTo ? $t('compose.placeholderReply') : $t('compose.placeholderNew')}
    ></textarea>
  </label>

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

  <div class="composer-row">
    <label class="chip">
      {$t('compose.addImage')}
      <input
        bind:this={fileInput}
        type="file"
        accept="image/*"
        multiple
        onchange={onFiles}
        style="display: none;"
      />
    </label>

    <!-- DM では、どれも使わない。可視性の select は出さないだけでなく、
         出してはいけない ─ 手が滑って公開に切り替わった一通は取り返せない。 -->
    {#if !dm}
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

      <label class="stack-tight">
        <span class="visually-hidden">{$t('compose.visLabel')}</span>
        <select bind:value={visibility}>
          {#each Object.entries(visLabels) as [v, label] (v)}
            <option value={v}>{label}</option>
          {/each}
        </select>
      </label>
    {/if}

    <button type="submit" class="btn px-6 py-2" disabled={!canPost}>
      {posting ? $t('common.sending') : uploading ? $t('compose.uploading') : $t('compose.submit')}
    </button>
  </div>

  {#if error}
    <p class="error">{error}</p>
  {/if}
</form>
