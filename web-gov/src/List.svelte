<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<script>
  import { applications, ApiError, sayError } from './api.js';
  import { ago, receiptText, weekdayName } from './format.js';

  let { oncount, onexpired } = $props();
  let data = $state(null);
  let error = $state('');

  $effect(() => {
    applications
      .list()
      .then((d) => {
        data = d;
        oncount(d.applications.length);
      })
      .catch((e) => {
        // トークンが合わないなら、閉じて窓口へ。
        if (e instanceof ApiError && e.status === 401) return onexpired();
        error = sayError(e);
      });
  });

</script>

<section>
  <h1>申し込み</h1>
  {#if error}
    <p class="err" role="alert">{error}</p>
  {:else if !data}
    <p class="muted">ひらいています…</p>
  {:else}
    <p class="muted">
      待っている {data.applications.length} 件。
      {#if data.next_check}次に確認するのは、<b>{weekdayName(data.next_check.weekday)}({data.next_check.days_after}日後)</b> と、書いてあります。{/if}
    </p>
    <ul class="apps">
      {#each data.applications as a (a.receipt)}
        <li>
          <a class="app" href={`#/applications/${a.receipt}`}>
            <span class="row"><b>{a.call_name || '(書いていません)'}</b><span class="tag wait">待っています</span></span>
            {#if a.snippet}<span class="snip">{a.snippet}</span>{/if}
            <span class="meta"><span>受付番号 {receiptText(a.receipt)}</span><span>{ago(a.created_at)}</span></span>
          </a>
        </li>
      {/each}
    </ul>
    {#if data.applications.length === 0}<p class="muted">いま、待っている申し込みは、ありません。</p>{/if}
    <p class="small muted">「はい」を押していない申し込みは、ここには出ません(3時間で消えます)。</p>
  {/if}
</section>
