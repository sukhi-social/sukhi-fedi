<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<script>
  import { applications, ApiError, sayError } from './api.js';
  import { ago, receiptText } from './format.js';

  let { receipt, onexpired, ondone } = $props();
  let app = $state(null);
  let error = $state('');
  let note = $state('');
  let reason = $state('');
  let busy = $state(false);
  // 送ったあとの、ここに残すもの。
  let done = $state(null);

  $effect(() => {
    app = null;
    done = null;
    error = '';
    applications
      .show(receipt)
      .then((a) => (app = a))
      .catch((e) => {
        if (e instanceof ApiError && e.status === 401) return onexpired();
        error = sayError(e);
      });
  });

  async function send(kind) {
    if (busy) return;
    busy = true;
    error = '';
    try {
      if (kind === 'welcome') {
        const r = await applications.welcome(receipt, note);
        done = { kind, days: r.entry_valid_days };
      } else {
        await applications.decline(receipt, reason);
        done = { kind };
      }
      ondone();
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) return onexpired();
      error = sayError(e);
    } finally {
      busy = false;
    }
  }
</script>

{#if done}
  <section>
    {#if done.kind === 'welcome'}
      <h1>迎えのメールを送りました</h1>
      <p class="muted">{done.days}日のあいだ使える入り口を送りました。ここには、受付番号の記録だけが残ります。書いてもらったことと、メールのアドレスは、消えました。</p>
    {:else}
      <h1>お返事を送りました</h1>
      <p class="muted">書いてもらったことと、メールのアドレスは、消えました。</p>
    {/if}
    <div class="card"><div class="row"><span class="tag">{done.kind === 'welcome' ? '迎えた' : '見送った'}</span><span class="small muted">受付番号 {receiptText(receipt)}</span></div></div>
    <p><a class="btn primary" href="#/applications">申し込みへ もどる</a></p>
  </section>
{:else}
  <section>
    <p class="small"><a href="#/applications">← 申し込み</a></p>
    {#if error && !app}
      <p class="err" role="alert">{error}</p>
    {:else if !app}
      <p class="muted">ひらいています…</p>
    {:else}
      <h1>{app.call_name ? `${app.call_name} さん` : '(名前は書いていません)'}</h1>
      <p class="small muted">受付番号 {receiptText(app.receipt)} · {ago(app.created_at)} · 返事は、{app.check_on} までに</p>
      <dl class="words card">
        <div><dt>1. なんて呼んだらいいですか？</dt><dd>{app.call_name || '—'}</dd></div>
        <div><dt>2. どこで、sukhi のことを知りましたか？</dt><dd>{app.found || '—'}</dd></div>
        <div><dt>3. ここで、どんなふうに過ごせたらいいなと思いますか？</dt><dd>{app.hope || '—'}</dd></div>
      </dl>
      <p class="note">メールアドレスは、ここには出しません。送るときだけ、サーバが使います。</p>

      <h2>返事</h2>
      <div class="card">
        <p class="small muted">迎えるときは、14日のあいだ、一回きりの入り口がメールで届きます。切れたら、もういちど申し込んでもらいます(特別扱いは、しません)。</p>
        <label class="small muted" for="note">心に残ったことを、ひとこと(そのままメールに入ります・500字まで)</label>
        <textarea id="note" bind:value={note} maxlength="500"></textarea>
        <div class="row">
          <button class="btn primary" disabled={busy} onclick={() => send('welcome')}>迎える</button>
          <a class="btn" href="#/applications">あとで読む</a>
        </div>
      </div>
      <details>
        <summary>今回は、お迎えしない</summary>
        <div class="card" style="margin-top:.6rem">
          <p class="small muted">理由は、短く、やさしく。「基準」のことばで書きます(500字まで)。やわらかい返事をメールで送って、書いてもらったことは消します。</p>
          <textarea aria-label="お迎えしない理由" bind:value={reason} maxlength="500"></textarea>
          <div class="row"><button class="btn" disabled={busy} onclick={() => send('decline')}>返事を送る</button></div>
        </div>
      </details>
      {#if error}<p class="err" role="alert">{error}</p>{/if}
    {/if}
  </section>
{/if}
