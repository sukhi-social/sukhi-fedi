<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<script>
  import { suspensions, ApiError, sayError } from './api.js';
  import { evidenceText, until } from './format.js';

  let { onexpired } = $props();
  let rows = $state(null);
  let error = $state('');
  let busy = $state('');

  function load() {
    suspensions
      .list()
      .then((d) => (rows = d.suspensions))
      .catch(fail);
  }

  function fail(e) {
    if (e instanceof ApiError && e.status === 401) return onexpired();
    error = sayError(e);
  }

  $effect(load);

  // 無視する / やめる。相手の記録は変わらない。ここでの配送だけが、すぐ普通に戻る(やめれば、また休む)。
  async function choose(row) {
    if (busy) return;
    busy = row.id;
    error = '';
    try {
      await (row.ignored ? suspensions.unignore(row.id) : suspensions.ignore(row.id));
      load();
    } catch (e) {
      fail(e);
    } finally {
      busy = '';
    }
  }
</script>

<section>
  <h1>配送のお休み</h1>
  <p class="muted">
    ほかのサーバーから「しばらく届けないで」と頼まれているものです。相手の記録は、ここからは変えません。
    「ここでは無視する」を選ぶと、こちらからの配送は、すぐふつうに戻ります(相手の記録は、そのままです)。
  </p>
  {#if error}
    <p class="err" role="alert">{error}</p>
  {/if}
  {#if !rows}
    {#if !error}<p class="muted">ひらいています…</p>{/if}
  {:else if rows.length === 0}
    <p class="muted">いま、頼まれているお休みは、ありません。</p>
  {:else}
    <ul class="apps">
      {#each rows as r (r.id)}
        <li class="card">
          <div class="row">
            <b>{r.target}</b>
            {#if r.ignored}
              <span class="tag">ここでは無視しています</span>
            {:else if r.in_effect}
              <span class="tag wait">休んでいます · {until(r.effective_end)}</span>
            {:else if r.status === 'cancelled'}
              <span class="tag">取り下げられました</span>
            {:else}
              <span class="tag">{until(r.effective_end)}</span>
            {/if}
          </div>
          {#if r.summary}<div class="small">{@html r.summary}</div>{/if}
          <dl class="meta-list small muted">
            <div><dt>頼んだ人</dt><dd>{r.controller}</dd></div>
            <div><dt>対象</dt><dd>{r.target_kind === 'origin' ? 'サーバー全体' : 'この inbox だけ'}</dd></div>
            <div><dt>版</dt><dd>{r.revision}</dd></div>
            <div><dt>確かめ</dt><dd>{evidenceText(r.evidence)}</dd></div>
            {#if r.held > 0}<div><dt>いま待たせている配送</dt><dd>{r.held}(この人のぶん)</dd></div>{/if}
          </dl>
          <div class="row">
            <button class="btn" disabled={busy === r.id} onclick={() => choose(r)}>
              {r.ignored ? '無視をやめる' : 'ここでは無視する'}
            </button>
            {#if r.url}
              <a class="small" href={r.url} rel="noopener noreferrer nofollow" target="_blank">相手のお知らせの頁</a>
            {/if}
          </div>
        </li>
      {/each}
    </ul>
  {/if}
</section>
