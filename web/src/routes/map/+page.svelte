<script lang="ts">
  import { onMount } from 'svelte';
  import { t, locale } from '$lib/i18n';

  // この星の路線図。駅も線路も比喩だけれど、形は docs/ARCHITECTURE.md の
  // 実配線と一対一に対応させてある。数字は公開の `GET /api/map` から、
  // この 1 日の数(note と、連合へ届けた便)。1 日基準なのは、しずかな星
  // でも「この星の一日」が見えるように。線路は、数字が取れなくても描ける。

  type StreamState = { seq: number; held: number } | null;
  type MapSample = {
    at: string;
    streams: { outbox: StreamState; outbox_dlq: StreamState; events: StreamState };
    notes_24h: { local: number; remote: number };
    deliveries_24h: number;
  };

  let sample = $state<MapSample | null>(null);
  let failed = $state(false);
  let reducedMotion = $state(false);

  async function poll() {
    try {
      const res = await fetch('/api/map');
      if (!res.ok) throw new Error(String(res.status));
      sample = await res.json();
      failed = false;
    } catch {
      failed = true;
    }
  }

  onMount(() => {
    reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    poll();
    const iv = setInterval(poll, 30_000);
    return () => clearInterval(iv);
  });

  // 1 日の数 → 列車の本数。桁でゆっくり増える(1-9→1, 10-99→2, 100-999→3, …)。
  const trains = (n: number, max = 4) =>
    n <= 0 ? 0 : Math.min(max, Math.floor(Math.log10(n)) + 1);

  let frontTrains = $derived(sample ? trains(sample.notes_24h.local, 3) : 0);
  let fedInTrains = $derived(sample ? trains(sample.notes_24h.remote) : 0);
  let fedOutTrains = $derived(sample ? trains(sample.deliveries_24h) : 0);
  // 場内放送の中身は「新しい投稿のお知らせ」そのもの。実配線は plain NATS の
  // stream.new_post(JetStream に載らず数を刻まない)なので、放送される中身
  // =この 1 日の note 数で数える。
  let newPosts24h = $derived(sample ? sample.notes_24h.local + sample.notes_24h.remote : null);
  let sseTrains = $derived(newPosts24h != null ? trains(newPosts24h, 3) : 0);
  let dlqHeld = $derived(sample?.streams.outbox_dlq?.held ?? null);

  let fedRunning = $derived(sample != null && sample.streams.outbox != null);

  let asOf = $derived(
    sample ? new Date(Date.parse(sample.at)).toLocaleTimeString($locale) : null
  );
</script>

<svelte:head>
  <title>{$t('map.title')}</title>
</svelte:head>

<section class="hero">
  <h1>{$t('map.title')}</h1>
  <p class="tagline">{$t('map.tagline')}</p>
</section>

<section class="section map-scroll">
  <svg viewBox="0 42 960 492" role="img" aria-label={$t('map.title')}>
    <!-- sukhi 中央駅の構内 -->
    <rect class="station-box" x="560" y="110" width="280" height="330" rx="8" />
    <text class="lbl lbl-bold" x="576" y="136">{$t('map.sukhi')}</text>

    <!-- おもて口線(HTTPS): あなた → Cloudflare 宇宙港 → Anubis 検問所 → gateway -->
    <path id="p-front" class="track use" d="M 100 160 H 612" />
    <text class="line-name use" x="150" y="182">{$t('map.lineFront')}</text>

    <!-- 場内放送の軽電鉄(SSE): gateway → あなた の専用ライン。行きの線とは
         別に、サーバから押し流す長生きのストリームが一本あるのは実配線どおり -->
    <path id="p-lightrail" class="track-light" d="M 612 152 Q 606 144 594 144 H 118 Q 108 144 103 152" />
    <text class="line-name muted" x="152" y="136">{$t('map.lightRail')}</text>

    <!-- 進行方向の矢印。塗りの小さな三角を、線には乗せず、始点のわき・
         進行方向の右側に(この地図は右側通行——対向線が左手にある配置)。
         WT だけは duplex なので両向きの一対 -->
    <path class="dir use" d="M 126 164.5 L 134 169 L 126 173.5 Z" />
    <path class="dir muted" d="M 552 132.5 L 544 137 L 552 141.5 Z" />
    <path class="dir build" d="M 326 176.5 L 334 181 L 326 185.5 Z" />
    <path class="dir build" d="M 796 340.5 L 804 345 L 796 349.5 Z" />
    <path class="dir build" d="M 863.5 320 L 868 311 L 872.5 320 Z" />
    <path class="dir build" d="M 840 84.5 L 831 89 L 840 93.5 Z" />
    <path class="dir ink" d="M 234 463.5 L 226 468 L 234 472.5 Z" />
    <path class="dir ink" d="M 242 463.5 L 250 468 L 242 472.5 Z" />

    <!-- 島のきわ。ここから先は連合宇宙(星は飾りだけれど、宇宙はほんとう) -->
    <path class="frontier" d="M 852 78 V 138 M 852 182 V 445" />
    <circle class="star" cx="925" cy="80" r="2" />
    <circle class="star" cx="945" cy="235" r="1.6" />
    <circle class="star" cx="935" cy="170" r="1.4" />
    <circle class="star" cx="900" cy="440" r="2" />
    <circle class="star" cx="940" cy="390" r="1.5" />

    <!-- 連合線(ActivityPub): 出は delivery から急行で発着場へ、そこから航路。
         入りは宇宙港(Cloudflare)に着いて、おもて口線で gateway へ -->
    <path id="p-fedout-rail" class="track build" d="M 779 336 H 842" />
    <path id="p-route-out" class="route" d="M 854 328 Q 888 246 879 132" />
    <!-- 入りの航路は、旅客の丸(宇宙港)ではなく貨物船ターミナルに降りる。
         港の上空を越えて、左まわりに四分円で降下して、ターミナルの左舷へ -->
    <path id="p-route-in" class="route" d="M 866 112 Q 560 20 300 100 Q 238 112 236 152 Q 234 190 271 196" />
    <!-- 貨物急行: 宇宙港に着いた連合の便は、Anubis の検問所に止まらず gateway へ。
         実配線どおり(/inbox 等は Anubis の素通しリスト)。検問所の下を抜ける複線 -->
    <!-- 宇宙港のすぐ下に貨物船ターミナル。線形は 宇宙港-(下)->ターミナル
         -(上右へ丸く)->gateway -->
    <path class="track build" d="M 280 174 V 189" />
    <path
      id="p-express"
      class="track build"
      d="M 287 196 Q 310 196 314 184 Q 317 172 336 172 H 588 Q 604 172 610 166"
    />
    <text class="line-name build" x="430" y="188">{$t('map.express')}</text>
    <rect class="dock" x="273" y="190" width="14" height="14" rx="2" />
    <text class="lbl-sub" x="280" y="218" text-anchor="middle">{$t('map.freightTerminal')}</text>
    <text class="line-name build" x="600" y="56">{$t('map.lineFed')}</text>

    <!-- WT 新幹線(試運転中): あなた → karutte(x64) → WireGuard 専用線 → WT ホーム -->
    <path id="p-wt" class="track wt" d="M 100 166 V 480 H 578 Q 600 480 600 458 V 428" />
    <path class="hair" d="M 322 486 H 560" />
    <text class="line-name ink" x="150" y="470">{$t('map.lineWt')}</text>
    <text class="chip-trial" x="440" y="470">{$t('map.statusTrial')}</text>
    <text class="lbl-sub" x="440" y="502" text-anchor="middle">{$t('map.wgTrunk')}</text>

    <!-- 構内連絡: gateway → api → NATS 操車場 → delivery、操車場 → WT ホーム -->
    <path class="hair" d="M 620 168 V 250 L 638 264" />
    <path class="hair" d="M 640 264 H 780 M 640 274 H 780 M 640 284 H 780" />
    <path class="hair" d="M 780 274 L 796 288 V 318 L 780 332" />
    <path class="hair" d="M 600 410 V 302 L 626 286" />
    <text class="lbl-sub" x="640" y="252">{$t('map.yard')}</text>

    <!-- DLQ 側線: 操車場から右上へ。届かなかった列車が 30 日待つところ -->
    <path class="hair" d="M 780 264 L 800 248 H 828" />
    <path class="hair stop" d="M 828 242 V 254" />
    <text class="lbl-sub" x="806" y="236" text-anchor="middle">{$t('map.siding')}</text>
    {#if dlqHeld != null && dlqHeld > 0}
      {#each Array(Math.min(dlqHeld, 3)) as _, i (i)}
        <rect class="held-car" x={800 + i * 10} y="244" width="8" height="7" rx="2" />
      {/each}
    {/if}

    <!-- 駅たち -->
    <circle class="station terminus" cx="100" cy="160" r="8" />
    <text class="lbl" x="100" y="138" text-anchor="middle">{$t('map.you')}</text>
    <circle class="port-ring" cx="280" cy="160" r="12" />
    <circle class="station" cx="280" cy="160" r="6" />
    <text class="lbl" x="280" y="120" text-anchor="middle">{$t('map.port')}</text>
    <!-- 検問所は駅(丸)ではなく、おもて口線をまたぐ関所のバー。
         下の貨物急行には届かない=連合の便は検問を受けない -->
    <path class="checkpoint" d="M 450 151 V 169" />
    <text class="lbl" x="450" y="140" text-anchor="middle">{$t('map.anubis')}</text>
    <circle class="station" cx="620" cy="160" r="6" />
    <text class="lbl" x="634" y="164">gateway</text>
    <circle class="station sm" cx="620" cy="215" r="5" />
    <text class="lbl" x="634" y="219">api</text>
    <circle class="station sm" cx="772" cy="336" r="5" />
    <text class="lbl" x="772" y="358" text-anchor="middle">delivery</text>
    <circle class="station sm" cx="600" cy="420" r="5" />
    <text class="lbl" x="614" y="424">{$t('map.wtPlatform')}</text>
    <rect class="dock" x="844" y="330" width="12" height="12" rx="2" />
    <text class="lbl-sub" x="838" y="318" text-anchor="end">{$t('map.dock')}</text>
    <circle class="station terminus" cx="880" cy="120" r="8" />
    <text class="lbl" x="880" y="152" text-anchor="middle">{$t('map.fediverse')}</text>
    <text class="lbl-sub" x="880" y="168" text-anchor="middle">{$t('map.fediverseSub')}</text>
    <circle class="station" cx="305" cy="480" r="6" />
    <text class="lbl" x="305" y="508" text-anchor="middle">{$t('map.karutte')}</text>
    <text class="lbl-sub" x="305" y="523" text-anchor="middle">{$t('map.karutteSub')}</text>

    <!-- 乗り物。数は実流量から。線路の上は車輪つきの貨車、宇宙は小さな
         ロケット。どれもゆったり。動きを減らす設定のときは、隠すのでは
         なく、道すじの途中に静かに停めて見せる(keyPoints を同値にピン留め
         した SMIL は、位置決めだけして動かない)。 -->
    {#snippet ride(path: string, dur: number, count: number, i: number, shuttle = false)}
      {#if reducedMotion}
        {@const p = (i + 1) / (count + 1)}
        <animateMotion
          dur="1s"
          fill="freeze"
          rotate="auto"
          calcMode="linear"
          keyPoints="{p};{p}"
          keyTimes="0;1"
        >
          <mpath href={path} />
        </animateMotion>
      {:else}
        <animateMotion
          dur="{dur}s"
          begin="{(-i * dur) / count}s"
          repeatCount="indefinite"
          rotate="auto"
          keyPoints={shuttle ? '0;1;0' : '0;1'}
          keyTimes={shuttle ? '0;0.5;1' : '0;1'}
          calcMode="linear"
        >
          <mpath href={path} />
        </animateMotion>
      {/if}
    {/snippet}
    {#snippet boxcar(cls: string, path: string, dur: number, count: number, i: number)}
      <g class="train {cls}">
        <rect x="-6.5" y="-6.5" width="13" height="9" rx="2" />
        <circle class="wheel" cx="-3.5" cy="3.6" r="1.5" />
        <circle class="wheel" cx="3.5" cy="3.6" r="1.5" />
        {@render ride(path, dur, count, i)}
      </g>
    {/snippet}
    {#snippet rocket(path: string, dur: number, count: number, i: number)}
      <g class="train build">
        <path d="M -5 0 L -9.5 -4.5 L -7.5 0 L -9.5 4.5 Z" />
        <path d="M -6.5 -3 H 1 Q 9 0 1 3 H -6.5 Z" />
        <circle class="window" cx="-1.5" cy="0" r="1.3" />
        {@render ride(path, dur, count, i)}
      </g>
    {/snippet}
    <!-- 新幹線は両頭(実物どおり)。WT は duplex なので往復運転が正確 -->
    {#snippet shinkansen(path: string, dur: number, count: number, i: number)}
      <g class="train ink">
        <path d="M -12.5 0 Q -9 -3.5 -2 -3.5 H 2 Q 9 -3.5 12.5 0 Q 9 3.5 2 3.5 H -2 Q -9 3.5 -12.5 0 Z" />
        <rect class="window" x="-3.5" y="-2.2" width="7" height="1.7" rx="0.85" />
        {@render ride(path, dur, count, i, true)}
      </g>
    {/snippet}
    {#snippet densha(path: string, dur: number, count: number, i: number)}
      <g class="train use">
        <rect x="-7" y="-6.5" width="14" height="9" rx="2.5" />
        <rect class="window" x="-4.6" y="-4.6" width="3.6" height="2.6" rx="0.9" />
        <rect class="window" x="1" y="-4.6" width="3.6" height="2.6" rx="0.9" />
        <circle class="wheel" cx="-3.8" cy="3.6" r="1.5" />
        <circle class="wheel" cx="3.8" cy="3.6" r="1.5" />
        {@render ride(path, dur, count, i)}
      </g>
    {/snippet}
    {#snippet tram(path: string, dur: number, count: number, i: number)}
      <g class="train lr">
        <rect x="-5" y="-5" width="10" height="7" rx="2" />
        <rect class="window" x="-1.6" y="-3.2" width="3" height="2" rx="0.8" />
        <circle class="wheel" cx="-2.6" cy="3.2" r="1.2" />
        <circle class="wheel" cx="2.6" cy="3.2" r="1.2" />
        {@render ride(path, dur, count, i)}
      </g>
    {/snippet}
    <!-- あなた→gateway はことばの電車、gateway→あなた は帰り専用の軽電鉄。
         在来線はどれもゆっくり。新幹線だけが、くらべて速い(ほぼ倍速) -->
    {#each Array(frontTrains) as _, i (i)}
      {@render densha('#p-front', 28, frontTrains, i)}
    {/each}
    {#each Array(sseTrains) as _, i (i)}
      {@render tram('#p-lightrail', 30, sseTrains, i)}
    {/each}
    <!-- 入りの便: ロケットが宇宙港に降りて、貨物急行の貨車に積み替わる -->
    {#each Array(fedInTrains) as _, i (i)}
      {@render rocket('#p-route-in', 40, fedInTrains, i)}
      {@render boxcar('build', '#p-express', 24, fedInTrains, i)}
    {/each}
    <!-- 出る便: delivery から貨車で発着場へ、そこからロケットで宇宙へ -->
    {#each Array(fedOutTrains) as _, i (i)}
      {@render boxcar('build', '#p-fedout-rail', 18, fedOutTrains, i)}
      {@render rocket('#p-route-out', 22, fedOutTrains, i)}
    {/each}
    <!-- WT 新幹線の試運転列車。これだけは実流量ではなく「試運転中」という
         状態を描く一本(開業したら実数につなぎ替える)。duplex なので往復 -->
    {@render shinkansen('#p-wt', 44, 1, 0)}
  </svg>
</section>

<!-- 発車標。数字はぜんぶ本物、取れないときは取れないと言う -->
<section class="section board measure">
  <h2>
    {$t('map.boardTitle')}
    {#if asOf}<span class="asof">{$t('map.boardAsOf', { time: asOf })}</span>{/if}
  </h2>
  {#if failed}
    <p class="board-error">{$t('map.boardError')}</p>
  {/if}
  <ul class="board-list">
    <li>
      <span class="chip" style="--line: var(--color-use)">{$t('map.lineFront')}</span>
      <span class="status">{$t('map.statusRunning')}</span>
      <p>
        {$t('map.boardFront')}
        {#if sample}{$t('map.boardFrontTrains', { n: sample.notes_24h.local })}{/if}
      </p>
    </li>
    <li>
      <span class="chip" style="--line: var(--color-build)">{$t('map.lineFed')}</span>
      <span class="status">
        {sample == null
          ? $t('map.measuring')
          : fedRunning
            ? $t('map.statusRunning')
            : $t('map.statusSuspended')}
      </span>
      <p>
        {sample == null
          ? $t('map.measuring')
          : $t('map.boardFedOut', { n: sample.deliveries_24h })}
        {#if sample}{$t('map.boardFedIn', { n: sample.notes_24h.remote })}{/if}
        {#if dlqHeld != null}
          {#if dlqHeld > 0}
            <span class="held">{$t('map.boardSidingHeld', { n: dlqHeld })}</span>
          {:else}
            {$t('map.boardSidingEmpty')}
          {/if}
        {/if}
      </p>
    </li>
    <li>
      <span class="chip chip-wt">{$t('map.lineWt')}</span>
      <span class="status">{$t('map.statusTrial')}</span>
      <p>{$t('map.boardWt')}</p>
    </li>
    <li>
      <span class="chip" style="--line: var(--color-text-muted)">{$t('map.lineEvents')}</span>
      <span class="status">
        {sample == null
          ? $t('map.measuring')
          : fedRunning
            ? $t('map.statusRunning')
            : $t('map.statusSuspended')}
      </span>
      <p>
        {newPosts24h == null
          ? $t('map.measuring')
          : $t('map.boardEvents', { n: newPosts24h })}
      </p>
    </li>
  </ul>
</section>

<section class="section measure">
  <h2>{$t('map.aboutTitle')}</h2>
  <p class="prose-small">{$t('map.aboutFront')}</p>
  <p class="prose-small">{$t('map.aboutFed')}</p>
  <p class="prose-small">{$t('map.aboutWt')}</p>
  <p class="prose-small">{$t('map.aboutEvents')}</p>
  <p class="prose-small numbers-note">{$t('map.aboutNumbers')}</p>
</section>

<style>
  .map-scroll {
    overflow-x: auto;
  }

  svg {
    display: block;
    width: 100%;
    min-width: 720px;
    font-family: inherit;
  }

  .station-box {
    fill: var(--color-surface);
    stroke: var(--color-border-strong);
    stroke-width: 1.5;
  }

  .track {
    fill: none;
    stroke-width: 3.5;
    stroke-linecap: round;
  }
  .track.use {
    stroke: var(--color-use);
  }
  .track.build {
    stroke: var(--color-build);
  }
  .track.wt {
    stroke: var(--color-text);
    stroke-dasharray: 7 6;
  }

  /* 帰り専用の軽電鉄(SSE)。ほそく、しずかな線 */
  .track-light {
    fill: none;
    stroke: var(--color-text-muted);
    stroke-width: 2;
    stroke-linecap: round;
  }

  .hair {
    fill: none;
    stroke: var(--color-border-strong);
    stroke-width: 1.5;
  }
  .hair.stop {
    stroke: var(--color-text);
    stroke-width: 2.5;
  }

  /* 航路。線路ではなく、宇宙をわたる便の道すじ */
  .route {
    fill: none;
    stroke: var(--color-build);
    stroke-width: 2.5;
    stroke-dasharray: 1 7;
    stroke-linecap: round;
  }

  /* 島のきわ(連合宇宙とのさかいめ) */
  .frontier {
    fill: none;
    stroke: var(--color-border-strong);
    stroke-width: 1;
    stroke-dasharray: 2 8;
  }

  .star {
    fill: var(--color-border-strong);
  }

  .station {
    fill: var(--color-surface);
    stroke: var(--color-text);
    stroke-width: 2.5;
  }

  .port-ring {
    fill: none;
    stroke: var(--color-border-strong);
    stroke-width: 1.5;
  }

  /* 検問所のバー(駅ではないので丸にしない) */
  .checkpoint {
    fill: none;
    stroke: var(--color-text);
    stroke-width: 3;
    stroke-linecap: round;
  }

  /* 進行方向の矢印。塗りの三角で、線の色のまま、はっきりと */
  .dir {
    stroke: none;
    opacity: 0.85;
  }
  .dir.use {
    fill: var(--color-use);
  }
  .dir.build {
    fill: var(--color-build);
  }
  .dir.muted {
    fill: var(--color-text-muted);
  }
  .dir.ink {
    fill: var(--color-text);
  }

  .dock {
    fill: var(--color-surface);
    stroke: var(--color-text);
    stroke-width: 2.5;
  }
  .station.sm {
    stroke-width: 2;
  }
  .station.terminus {
    stroke-width: 3;
  }

  .lbl {
    fill: var(--color-text);
    font-size: 13px;
  }
  .lbl-bold {
    font-weight: 600;
  }
  .lbl-sub {
    fill: var(--color-text-muted);
    font-size: 11px;
  }
  .line-name {
    font-size: 11px;
    font-weight: 600;
  }
  .line-name.use {
    fill: var(--color-use);
  }
  .line-name.build {
    fill: var(--color-build);
  }
  .line-name.ink {
    fill: var(--color-text);
  }
  .line-name.muted {
    fill: var(--color-text-muted);
    font-weight: 400;
  }
  .chip-trial {
    fill: var(--color-text-muted);
    font-size: 11px;
  }

  /* 乗り物は <g> ごと塗る(貨車の箱もロケットの胴も fill を継ぐ) */
  .train.use {
    fill: var(--color-use);
  }
  .train.build {
    fill: var(--color-build);
  }
  .train.ink {
    fill: var(--color-text);
  }
  .train.lr {
    fill: var(--color-text-muted);
  }
  .train .wheel {
    fill: var(--color-text);
  }
  .train .window {
    fill: var(--color-surface);
  }
  .held-car {
    fill: var(--color-danger);
  }

  /* ── 発車標 ── */
  .asof {
    margin-left: var(--space-2);
    font-size: var(--text-sm);
    font-weight: 400;
    color: var(--color-text-muted);
  }

  .board-error {
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .board-list {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  .board-list li {
    padding: var(--space-3) 0;
    border-top: 1px solid var(--color-border);
  }
  .board-list li:first-child {
    border-top: none;
  }
  .board-list p {
    margin: var(--space-1) 0 0;
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }

  .chip {
    display: inline-block;
    padding: 0 var(--space-2);
    border-radius: var(--radius-sm);
    background: var(--line);
    color: var(--color-surface);
    font-size: var(--text-sm);
    font-weight: 600;
  }
  .chip-wt {
    background: transparent;
    color: var(--color-text);
    border: 1.5px dashed var(--color-border-strong);
  }

  .status {
    margin-left: var(--space-2);
    font-size: var(--text-sm);
    color: var(--color-text-muted);
  }

  .held {
    color: var(--color-danger);
  }

  .numbers-note {
    color: var(--color-text-muted);
  }

  /* 解説の段落は、息つぎの間をあける(.stack は section 間にしか効かない) */
  .prose-small + .prose-small {
    margin-top: var(--space-3);
  }
</style>
