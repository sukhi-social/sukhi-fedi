<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<script>
  import { info } from './api.js';
  import { weekdayChar, weekdayName } from './format.js';

  let { auth, notice = '', onlogin } = $props();
  let data = $state(null);

  $effect(() => {
    info().then((i) => (data = i));
  });

  const who = $derived(data?.greeter || 'ここを見ている人');
</script>

<div class="public main">
  <section class="hero">
    <h1>ここの窓口です</h1>
    <p class="lead">sukhi を見ている人たちと、困ったときの、ここでのやりかたを、書いてあります。入らなくても、読めます。</p>
  </section>

  <section>
    <h2>いま、見ている人</h2>
    <div class="card">
      <p><b>{who}</b> が、申し込みを見ています。</p>
      {#if data}
        <p class="small muted">つぎに確認するのは、{weekdayName(data.weekday)}({data.days_after}日後)です。</p>
        <div class="days" role="img" aria-label={weekdayName(data.weekday)}>
          {#each [1, 2, 3, 4, 5, 6, 7] as d}
            <span class="day" data-on={d === data.weekday ? '' : undefined}>{weekdayChar(d)}</span>
          {/each}
        </div>
      {/if}
      <p class="small muted">返事は、一週間以内に、メールでお返しします。</p>
    </div>
  </section>

  <section>
    <h2>受け入れる基準</h2>
    <div class="card">
      <p>「断る基準」ではなく、「受け入れる基準」を書きます。</p>
      <p>ゆっくり時間をかけて待てる人、ここで静かに過ごせる人を、望んでいます。気になっただけ、でも大丈夫です。</p>
      <p class="small muted">誘われた人も、同じ申し込みを通ります。身内ノリを防ぐためです。</p>
    </div>
    <div class="row"><a class="btn primary" href="https://sukhi.social/join">申し込む</a><a class="btn" href="https://sukhi.social/terms">規約を読む</a></div>
  </section>

  {#if !auth}
    <section class="gate">
      <h3 class="small muted">ここを見ている人の方へ</h3>
      <p class="small muted">この頁は、だれでも見られます。ログインすると、迎える道具が、ここに足されます。管理する人のアカウントだけが、通れます。</p>
      {#if notice}<p class="err small" role="alert">{notice}</p>{/if}
      <div class="row"><button class="btn" onclick={onlogin}>ログインして、ひらく</button></div>
    </section>
  {/if}
</div>
