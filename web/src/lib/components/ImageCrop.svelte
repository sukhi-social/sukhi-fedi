<script lang="ts">
  // 画像を、決まった比率にそっと切り抜くための小さな窓。
  //
  // 外部ライブラリは使わず、枠ひとつ・ドラッグ・ズームのつまみ・canvas
  // だけで作る。枠はいつも aspect の比率(アバターは 1、ヘッダーは 3)。
  // 画像はその裏で動かせて、最後に枠に見えている範囲だけを outWidth ×
  // outHeight の canvas に焼いて、File にして返す。
  //
  // 動く GIF を切ると、最初の一コマだけの静止画になる ─ 切り抜きは
  // どうしてもラスタライズなので、ここは諦める。
  import { t } from '$lib/i18n';

  let {
    file,
    aspect,
    outWidth,
    outHeight,
    outMime = 'image/jpeg',
    title,
    ondone,
    oncancel
  }: {
    file: File;
    aspect: number; // 横 / 縦
    outWidth: number;
    outHeight: number;
    outMime?: 'image/jpeg' | 'image/png';
    title: string;
    ondone: (file: File) => void;
    oncancel: () => void;
  } = $props();

  // 読み込んだ画像。File から object URL を作って <img> に渡し、外したら revoke。
  let src = $state<string | null>(null);
  $effect(() => {
    const url = URL.createObjectURL(file);
    src = url;
    return () => URL.revokeObjectURL(url);
  });

  let imgEl = $state<HTMLImageElement>();
  let frameEl = $state<HTMLDivElement>();

  // 画像の素の大きさ(自然サイズ)。読み込めてから入る。
  let nw = $state(0);
  let nh = $state(0);
  // 枠の実寸(CSS で決まる)。bind:clientWidth/Height で測る。
  let fw = $state(0);
  let fh = $state(0);

  // 画面上での縮尺(自然1pxが画面で何pxになるか)と、画像左上の位置。
  // baseScale は「枠をちょうど覆う」最小の縮尺。zoom はそこからの倍率。
  let baseScale = $state(1);
  let scale = $state(1);
  let zoom = $state(1);
  let tx = $state(0);
  let ty = $state(0);

  const MAX_ZOOM = 4;

  // 画像と枠が両方そろったら、覆う縮尺で中央に置きなおす。file が
  // 変わったとき(別の画像を選び直したとき)もここから組み直す。
  //
  // **書いたものを、この中で読み返さない。** 前は tx/ty の行で `scale` を
  // 読んでいて、それが依存に乗っていた ── つまり `scale` が変わるたびに
  // この effect が起き直して `zoom = 1` に戻していた。つまみを動かしても
  // 描き直した瞬間に必ず 1 へ帰るので、画像はぴくりとも動かない。
  // 「触れない」ように見えていたのは、これ(指の問題ではなかった)。
  //
  // 直しは、いま計算した値を手元の `s` で持ちまわるだけ。rune を読まない。
  $effect(() => {
    if (!nw || !nh || !fw || !fh) return;
    const s = Math.max(fw / nw, fh / nh);
    baseScale = s;
    zoom = 1;
    scale = s;
    tx = (fw - nw * s) / 2;
    ty = (fh - nh * s) / 2;
  });

  // 画像はいつも枠を覆ったまま ─ はみ出しを許す向きにだけ動かせる。
  function clamp() {
    tx = Math.min(0, Math.max(fw - nw * scale, tx));
    ty = Math.min(0, Math.max(fh - nh * scale, ty));
  }

  function onImgLoad() {
    if (!imgEl) return;
    nw = imgEl.naturalWidth;
    nh = imgEl.naturalHeight;
  }

  // ── ドラッグで動かす ────────────────────────────────────────────
  let dragging = false;
  let startX = 0;
  let startY = 0;
  let startTx = 0;
  let startTy = 0;

  function onPointerDown(e: PointerEvent) {
    dragging = true;
    startX = e.clientX;
    startY = e.clientY;
    startTx = tx;
    startTy = ty;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function onPointerMove(e: PointerEvent) {
    if (!dragging) return;
    tx = startTx + (e.clientX - startX);
    ty = startTy + (e.clientY - startY);
    clamp();
  }

  function onPointerUp(e: PointerEvent) {
    dragging = false;
    (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
  }

  // ── ズーム ──────────────────────────────────────────────────────
  // 枠の中心に見えている点を留めたまま、縮尺だけ変える。
  function applyZoom(next: number) {
    const z = Math.min(MAX_ZOOM, Math.max(1, next));
    const cx = fw / 2;
    const cy = fh / 2;
    const ix = (cx - tx) / scale;
    const iy = (cy - ty) / scale;
    zoom = z;
    scale = baseScale * z;
    tx = cx - ix * scale;
    ty = cy - iy * scale;
    clamp();
  }

  function onZoomInput(e: Event) {
    applyZoom(parseFloat((e.currentTarget as HTMLInputElement).value));
  }

  function onWheel(e: WheelEvent) {
    e.preventDefault();
    applyZoom(zoom * (e.deltaY < 0 ? 1.1 : 1 / 1.1));
  }

  // ── 切り抜いて返す ──────────────────────────────────────────────
  function done() {
    if (!imgEl || !nw) return;
    const canvas = document.createElement('canvas');
    canvas.width = outWidth;
    canvas.height = outHeight;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    // 枠に見えている範囲を、自然サイズの座標に直す。
    const sx = -tx / scale;
    const sy = -ty / scale;
    const sw = fw / scale;
    const sh = fh / scale;
    ctx.drawImage(imgEl, sx, sy, sw, sh, 0, 0, outWidth, outHeight);
    canvas.toBlob(
      (blob) => {
        if (!blob) return;
        const ext = outMime === 'image/png' ? 'png' : 'jpg';
        const base = file.name.replace(/\.[^.]+$/, '') || 'image';
        ondone(new File([blob], `${base}.${ext}`, { type: outMime }));
      },
      outMime,
      0.9
    );
  }
</script>

<div
  class="crop-backdrop"
  role="dialog"
  aria-modal="true"
  aria-label={title}
  tabindex="-1"
  onkeydown={(e) => e.key === 'Escape' && oncancel()}
>
  <div class="crop-panel">
    <p class="crop-title">{title}</p>

    <div
      class="crop-frame"
      role="group"
      aria-label={title}
      bind:this={frameEl}
      bind:clientWidth={fw}
      bind:clientHeight={fh}
      style="aspect-ratio: {aspect};"
      onpointerdown={onPointerDown}
      onpointermove={onPointerMove}
      onpointerup={onPointerUp}
      onpointercancel={onPointerUp}
      onwheel={onWheel}
    >
      {#if src}
        <img
          bind:this={imgEl}
          {src}
          alt=""
          draggable="false"
          onload={onImgLoad}
          style="transform: translate({tx}px, {ty}px) scale({scale});"
        />
      {/if}
    </div>

    <label class="crop-zoom">
      <span class="visually-hidden">{$t('crop.zoom')}</span>
      <input
        type="range"
        min="1"
        max={MAX_ZOOM}
        step="0.01"
        value={zoom}
        oninput={onZoomInput}
      />
    </label>

    <p class="crop-hint muted">{$t('crop.hint')}</p>

    <div class="crop-actions">
      <button type="button" class="chip" onclick={oncancel}>{$t('crop.cancel')}</button>
      <button type="button" class="btn px-6 py-2" onclick={done}>{$t('crop.confirm')}</button>
    </div>
  </div>
</div>

<style>
  /* 画面いっぱいに薄い幕を引いて、その上に小さな卓を置く。 */
  .crop-backdrop {
    position: fixed;
    inset: 0;
    z-index: 50;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: var(--space-4);
    background: rgb(0 0 0 / 0.45);
  }
  .crop-panel {
    width: min(92vw, 360px);
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    padding: var(--space-4);
    background: var(--color-bg);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
  }
  .crop-title {
    font-weight: 600;
  }
  /* 切り抜きの窓。中で画像を動かすので、はみ出しは隠す。 */
  .crop-frame {
    position: relative;
    width: 100%;
    overflow: hidden;
    background: var(--color-border);
    border-radius: var(--radius-sm);
    touch-action: none; /* ドラッグをスクロールに取られない */
    cursor: grab;
  }
  .crop-frame:active {
    cursor: grabbing;
  }
  .crop-frame img {
    position: absolute;
    top: 0;
    left: 0;
    transform-origin: 0 0;
    user-select: none;
    -webkit-user-drag: none;
    max-width: none; /* 自然サイズのまま transform で拡縮する */
  }
  .crop-zoom input {
    width: 100%;
    /* 指で掴めるように。素のままだと帯が 16px しかなくて、当たり判定が
       指より小さい。上下に余白を足して 44px の帯にし、つまみ自体も
       大きくする ── 動くようになっても、掴めなければ同じことなので。 */
    height: 44px;
    margin: 0;
    background: transparent;
    -webkit-appearance: none;
    appearance: none;
  }
  .crop-zoom input::-webkit-slider-runnable-track {
    height: 4px;
    border-radius: 999px;
    background: var(--color-border-strong);
  }
  .crop-zoom input::-moz-range-track {
    height: 4px;
    border-radius: 999px;
    background: var(--color-border-strong);
  }
  .crop-zoom input::-webkit-slider-thumb {
    -webkit-appearance: none;
    appearance: none;
    width: 28px;
    height: 28px;
    margin-top: -12px;
    border-radius: 999px;
    background: var(--color-surface);
    border: 1px solid var(--color-text);
    cursor: pointer;
  }
  .crop-zoom input::-moz-range-thumb {
    width: 28px;
    height: 28px;
    border: 1px solid var(--color-text);
    border-radius: 999px;
    background: var(--color-surface);
    cursor: pointer;
  }
  .crop-hint {
    margin: 0;
    text-align: center;
  }
  .crop-actions {
    display: flex;
    gap: var(--space-3);
    justify-content: flex-end;
  }
</style>
