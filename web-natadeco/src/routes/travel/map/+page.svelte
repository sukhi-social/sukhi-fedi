<script lang="ts">
  import { onMount } from 'svelte';
  import { listFlow, localized, type Post } from '$lib/api';
  import { TRAVEL_SLUG } from '$lib/site';
  import { t } from '$lib/i18n.svelte';
  import PageHeader from '$lib/PageHeader.svelte';
  import 'leaflet/dist/leaflet.css';

  // 場所のある記録だけが、ここに立つ。星も順位も無い ── ただ、
  // 誰かがそこに居た、という印。
  let mapEl = $state<HTMLDivElement | null>(null);
  let count = $state<number | null>(null);
  let error = $state<string | null>(null);

  function excerpt(html: string): string {
    const text = html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    return text.length > 80 ? text.slice(0, 80) + '…' : text;
  }

  function esc(s: string): string {
    return s.replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch] ?? ch);
  }

  onMount(async () => {
    const L = await import('leaflet');

    // 流れを、場所のあるものが尽きるまで辿る。上限は 5 頁 ── それより
    // 昔のぶんは、また今度。
    const pinned: Post[] = [];
    let before: number | undefined;
    try {
      for (let i = 0; i < 5; i++) {
        const rows = await listFlow(TRAVEL_SLUG, { beforeId: before });
        pinned.push(...rows.filter((r) => r.place && !r.in_reply_to_ap_id));
        if (rows.length < 40) break;
        before = rows.at(-1)?.id;
      }
    } catch {
      error = t().travel.notReady;
      return;
    }
    count = pinned.length;
    if (!mapEl) return;

    const map = L.map(mapEl, { zoomControl: true, attributionControl: true });
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
    }).addTo(map);

    // 44px の当たり判定の中に、小さな点(yum と同じ作り)。
    const icon = L.divIcon({ className: 'pin-hit', html: '<div class="pin"></div>', iconSize: [44, 44], iconAnchor: [22, 22] });
    const focus = location.hash.slice(1);
    let focused: L.Marker | null = null;
    const bounds = L.latLngBounds([]);

    for (const p of pinned) {
      const at: [number, number] = [p.place!.lat, p.place!.lng];
      bounds.extend(at);
      const m = L.marker(at, { icon }).addTo(map);
      const name = p.place!.name || t().travel.somewhere;
      m.bindPopup(
        `<strong>${esc(name)}</strong><br>${esc(excerpt(localized(p.content_html, p.content_html_i18n)))}` +
          `<br><a href="/d/travel/p/${p.id}">${esc(t().travel.open)}</a>` +
          `<span class="by"> — ${esc(p.author.display_name || p.author.acct)}</span>`
      );
      if (String(p.id) === focus) focused = m;
    }

    if (focused) {
      map.setView(focused.getLatLng(), 14);
      focused.openPopup();
    } else if (pinned.length > 0) {
      map.fitBounds(bounds.pad(0.2), { maxZoom: 13 });
    } else {
      map.setView([35.1587, 129.1604], 5);
    }
  });
</script>

<PageHeader title={t().travel.mapTitle} subtitle={count === 0 ? t().travel.mapEmpty : null} />

{#if error}<p class="muted">{error}</p>{/if}

<div class="map" bind:this={mapEl}></div>

<p class="back"><a href="/">{t().travel.back}</a></p>

<style>
  .map {
    height: min(70vh, 34rem);
    border-radius: var(--radius);
    border: 1px solid var(--line);
    overflow: hidden;
    background: var(--paper-raised);
  }

  .map :global(.pin-hit) {
    background: none;
    border: none;
    display: grid;
    place-items: center;
  }

  .map :global(.pin) {
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: var(--sun);
    border: 2px solid var(--paper-raised);
    box-shadow: 0 1px 6px -1px oklch(40% 0.1 75 / 50%);
  }

  .map :global(.leaflet-popup-content) {
    font-size: 0.9rem;
    line-height: 1.5;
  }

  .map :global(.by) {
    color: var(--ink-soft);
    font-size: 0.8rem;
  }

  .back {
    margin-top: 1.5rem;
  }
</style>
