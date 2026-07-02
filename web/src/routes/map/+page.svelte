<script lang="ts">
  import { onMount } from 'svelte';
  import { t, locale } from '$lib/i18n';

  // この星の路線図。駅も線路も比喩だけれど、形は docs/ARCHITECTURE.md の
  // 実配線と一対一に対応させてある。数字は公開の `GET /api/map`(粗い累積
  // カウンタだけ)を 15 秒ごとに引き、2 回の差分から「いまの流量」を出す。
  // 列車の本数はその流量から。線路そのものは、数字が取れなくても描ける。

  type StreamState = { seq: number; held: number } | null;
  type MapSample = {
    at: string;
    streams: { outbox: StreamState; outbox_dlq: StreamState; events: StreamState };
    notes_5m: { local: number; remote: number };
  };

  let sample = $state<MapSample | null>(null);
  let failed = $state(false);
  let outboxPerMin = $state<number | null>(null);
  let eventsPerMin = $state<number | null>(null);
  let reducedMotion = $state(false);

  let prev: { atMs: number; outboxSeq: number | null; eventsSeq: number | null } | null = null;

  async function poll() {
    try {
      const res = await fetch('/api/map');
      if (!res.ok) throw new Error(String(res.status));
      const body: MapSample = await res.json();
      const atMs = Date.parse(body.at);
      // サーバは 5 秒キャッシュを返すことがある。同じ瞬間の答えなら
      // 差分は取れない(dt=0)ので、そのときは前回のまま。
      if (prev && atMs > prev.atMs) {
        const dtMin = (atMs - prev.atMs) / 60_000;
        const oSeq = body.streams.outbox?.seq ?? null;
        const eSeq = body.streams.events?.seq ?? null;
        if (oSeq != null && prev.outboxSeq != null)
          outboxPerMin = Math.max(0, (oSeq - prev.outboxSeq) / dtMin);
        if (eSeq != null && prev.eventsSeq != null)
          eventsPerMin = Math.max(0, (eSeq - prev.eventsSeq) / dtMin);
      }
      if (!prev || atMs > prev.atMs) {
        prev = {
          atMs,
          outboxSeq: body.streams.outbox?.seq ?? null,
          eventsSeq: body.streams.events?.seq ?? null
        };
      }
      sample = body;
      failed = false;
    } catch {
      failed = true;
    }
  }

  onMount(() => {
    reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    poll();
    // キャッシュ窓(5秒)を越えた 2 回目で最初の差分が取れる。以後は 15 秒ごと。
    const second = setTimeout(poll, 7_000);
    const iv = setInterval(poll, 15_000);
    return () => {
      clearTimeout(second);
      clearInterval(iv);
    };
  });

  // 流量 → 列車の本数。すこしでも流れていれば 1 本は走らせる。
  const trains = (n: number, max = 4) => Math.max(0, Math.min(max, Math.ceil(n)));

  let frontTrains = $derived(sample ? trains(sample.notes_5m.local, 3) : 0);
  let fedInTrains = $derived(sample ? trains(sample.notes_5m.remote) : 0);
  let fedOutTrains = $derived(outboxPerMin != null ? trains(outboxPerMin * 5) : 0);
  let sseTrains = $derived(eventsPerMin != null ? trains(eventsPerMin * 5, 3) : 0);
  let dlqHeld = $derived(sample?.streams.outbox_dlq?.held ?? null);

  let fedRunning = $derived(sample != null && sample.streams.outbox != null);
  let eventsRunning = $derived(sample != null && sample.streams.events != null);

  const perMin = (r: number) => Math.round(r * 10) / 10;

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

    <!-- おもて口線(HTTPS): あなた → Cloudflare → Anubis 改札 → gateway -->
    <path id="p-front" class="track use" d="M 100 160 H 612" />
    <text class="line-name use" x="150" y="149">{$t('map.lineFront')}</text>

    <!-- 連合線(ActivityPub): 入りは表口へ、出は delivery から -->
    <path class="track build" d="M 890 328 V 82 Q 890 70 878 70 H 308 Q 280 70 280 98 V 150" />
    <path class="track build" d="M 779 336 H 880" />
    <text class="line-name build" x="560" y="60">{$t('map.lineFed')}</text>
    <!-- 列車用の通し道(入り: 各駅 → Cloudflare で表口線に合流 → gateway) -->
    <path
      id="p-fedin"
      class="ghost"
      d="M 890 328 V 82 Q 890 70 878 70 H 308 Q 280 70 280 98 V 150 Q 280 160 292 160 H 612"
    />
    <path id="p-fedout" class="ghost" d="M 779 336 H 880" />

    <!-- WT 直通線(試運転中): あなた → karutte(x64) → WireGuard 専用線 → WT ホーム -->
    <path class="track wt" d="M 100 166 V 480 H 578 Q 600 480 600 458 V 428" />
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
    <circle class="station" cx="280" cy="160" r="6" />
    <text class="lbl" x="280" y="140" text-anchor="middle">Cloudflare</text>
    <circle class="station" cx="450" cy="160" r="6" />
    <text class="lbl" x="450" y="140" text-anchor="middle">{$t('map.anubis')}</text>
    <circle class="station" cx="620" cy="160" r="6" />
    <text class="lbl" x="634" y="164">gateway</text>
    <circle class="station sm" cx="620" cy="215" r="5" />
    <text class="lbl" x="634" y="219">api</text>
    <circle class="station sm" cx="772" cy="336" r="5" />
    <text class="lbl" x="772" y="358" text-anchor="middle">delivery</text>
    <circle class="station sm" cx="600" cy="420" r="5" />
    <text class="lbl" x="614" y="424">{$t('map.wtPlatform')}</text>
    <circle class="station terminus" cx="890" cy="340" r="8" />
    <text class="lbl" x="890" y="370" text-anchor="middle">{$t('map.fediverse')}</text>
    <text class="lbl-sub" x="890" y="386" text-anchor="middle">{$t('map.fediverseSub')}</text>
    <circle class="station" cx="305" cy="480" r="6" />
    <text class="lbl" x="305" y="508" text-anchor="middle">{$t('map.karutte')}</text>
    <text class="lbl-sub" x="305" y="523" text-anchor="middle">{$t('map.karutteSub')}</text>

    <!-- 列車。本数は実流量から(prefers-reduced-motion では走らせない) -->
    {#if !reducedMotion}
      {#each Array(frontTrains) as _, i (i)}
        <rect class="train use" x="-8" y="-4.5" width="16" height="9" rx="4.5">
          <animateMotion dur="8s" begin="{-(i * 8) / frontTrains}s" repeatCount="indefinite" rotate="auto">
            <mpath href="#p-front" />
          </animateMotion>
        </rect>
      {/each}
      {#each Array(sseTrains) as _, i (i)}
        <circle class="train-dot" r="3.5">
          <animateMotion
            dur="6s"
            begin="{-(i * 6) / sseTrains}s"
            repeatCount="indefinite"
            keyPoints="1;0"
            keyTimes="0;1"
            calcMode="linear"
          >
            <mpath href="#p-front" />
          </animateMotion>
        </circle>
      {/each}
      {#each Array(fedInTrains) as _, i (i)}
        <rect class="train build" x="-8" y="-4.5" width="16" height="9" rx="4.5">
          <animateMotion dur="16s" begin="{-(i * 16) / fedInTrains}s" repeatCount="indefinite" rotate="auto">
            <mpath href="#p-fedin" />
          </animateMotion>
        </rect>
      {/each}
      {#each Array(fedOutTrains) as _, i (i)}
        <rect class="train build" x="-8" y="-4.5" width="16" height="9" rx="4.5">
          <animateMotion dur="7s" begin="{-(i * 7) / fedOutTrains}s" repeatCount="indefinite" rotate="auto">
            <mpath href="#p-fedout" />
          </animateMotion>
        </rect>
      {/each}
    {/if}
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
        {#if sample}{$t('map.boardFrontTrains', { n: sample.notes_5m.local })}{/if}
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
        {outboxPerMin == null
          ? $t('map.measuring')
          : $t('map.boardFedOut', { n: perMin(outboxPerMin) })}
        {#if sample}{$t('map.boardFedIn', { n: sample.notes_5m.remote })}{/if}
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
          : eventsRunning
            ? $t('map.statusRunning')
            : $t('map.statusSuspended')}
      </span>
      <p>
        {eventsPerMin == null
          ? $t('map.measuring')
          : $t('map.boardEvents', { n: perMin(eventsPerMin) })}
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

  /* 列車の通し道。線としては描かない(表口線に合流する部分の重ね描きを避ける) */
  .ghost {
    fill: none;
    stroke: none;
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

  .station {
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
  .chip-trial {
    fill: var(--color-text-muted);
    font-size: 11px;
  }

  .train.use {
    fill: var(--color-use);
  }
  .train.build {
    fill: var(--color-build);
  }
  .train-dot {
    fill: var(--color-text-muted);
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
