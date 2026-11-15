// SPDX-License-Identifier: AGPL-3.0-or-later
// 画像を、上げる前に、ブラウザでそっと整える。
//
//   ・選ぶ / Ctrl+V で貼る / 落とす ── どれも同じ道に入る。
//   ・向きを直して、大きすぎるものは縮める(スマホの写真は、8MB を軽く越える)。
//   ・カードに、見えるもの・alt・回す・切り抜く・はずす。
//   ・整えた画像は <input type=file> に戻す。送るのは、ふつうのフォーム送信のまま。
//
// このファイルは二つの顔を持つ。上半分は「純粋なところ」(DOM に触れない。node --test が読む)。
// 下半分はブラウザの中でだけ動く(`document` が無いときは、何もしない)。

export const MAX_EDGE = 2560; // 長いほうの辺。これより大きいものは縮める
export const KEEP_BYTES = 2 * 1024 * 1024; // これ以下で、向きも大きさも良ければ、手を付けない
export const LIMIT_BYTES = 8 * 1024 * 1024; // gateway の上限
export const BIG_PNG_BYTES = 4 * 1024 * 1024; // PNG がこれを越えたら、別の形も試す

// ── 純粋なところ ───────────────────────────────────────────────────

// 長い辺が maxEdge に収まるように。拡大はしない。
export function fitSize(w, h, maxEdge) {
  const k = Math.min(1, maxEdge / Math.max(w, h));
  return { w: Math.max(1, Math.round(w * k)), h: Math.max(1, Math.round(h * k)) };
}

// JPEG の頭にある EXIF の向き(1〜8)。読めなければ 1(そのまま)。
// APP1 の "Exif" → TIFF ヘッダ → 最初の IFD の 0x0112 を探すだけ。
export function jpegOrientation(bytes) {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.length < 4 || v.getUint16(0) !== 0xffd8) return 1;
  let p = 2;
  while (p + 4 <= bytes.length) {
    if (bytes[p] !== 0xff) return 1;
    const marker = bytes[p + 1];
    if (marker === 0xda || marker === 0xd9) return 1; // 画の本体まで来た
    const len = v.getUint16(p + 2);
    if (marker === 0xe1 && len >= 16 && p + 4 + 6 <= bytes.length && String.fromCharCode(...bytes.subarray(p + 4, p + 8)) === "Exif") {
      const t = p + 10; // TIFF ヘッダ
      if (t + 8 > bytes.length) return 1;
      const little = v.getUint16(t) === 0x4949;
      if (!little && v.getUint16(t) !== 0x4d4d) return 1;
      const u16 = (o) => (o + 2 <= bytes.length ? v.getUint16(o, little) : 0);
      const u32 = (o) => (o + 4 <= bytes.length ? v.getUint32(o, little) : 0);
      const ifd = t + u32(t + 4);
      const n = u16(ifd);
      for (let i = 0; i < n; i++) {
        const e = ifd + 2 + i * 12;
        if (u16(e) === 0x0112) {
          const o = u16(e + 8);
          return o >= 1 && o <= 8 ? o : 1;
        }
      }
      return 1;
    }
    p += 2 + len;
  }
  return 1;
}

// 手を付けるか。向きが違う・大きい・縮めたい、のどれかのとき。
export function needsWork({ type, size, orientation = 1, w, h }) {
  if (type === "image/jpeg") return orientation > 1 || size > KEEP_BYTES || Math.max(w, h) > MAX_EDGE;
  if (type === "image/png" || type === "image/webp") return size > KEEP_BYTES || Math.max(w, h) > MAX_EDGE;
  return false;
}

// 何度回すか(時計回りに 90°×rot)の、描く行列。w0・h0 は回す前の画の大きさ。
// 回したあとの座標 (X, Y) = (a·x + c·y + e, b·x + d·y + f)。
export function rotationMatrix(rot, w0, h0) {
  switch (((rot % 4) + 4) % 4) {
    case 1: return [0, 1, -1, 0, h0, 0];
    case 2: return [-1, 0, 0, -1, w0, h0];
    case 3: return [0, -1, 1, 0, 0, w0];
    default: return [1, 0, 0, 1, 0, 0];
  }
}

// 切り抜きの窓。画像は、窓をいつも覆う(はみ出しを許す向きにだけ動かせる)。
export const coverScale = (nw, nh, fw, fh) => Math.max(fw / nw, fh / nh);
export const clampOffset = (t, frame, size) => Math.min(0, Math.max(frame - size, t));

// 窓の中心に見えている点を留めたまま、縮尺だけ変える。
export function zoomKeepingCenter({ tx, ty, scale }, nextScale, fw, fh) {
  const ix = (fw / 2 - tx) / scale;
  const iy = (fh / 2 - ty) / scale;
  return { scale: nextScale, tx: fw / 2 - ix * nextScale, ty: fh / 2 - iy * nextScale };
}

// 窓に見えている範囲を、画像全体に対する割合(0〜1)で。
export function visibleFraction({ tx, ty, scale }, fw, fh, nw, nh) {
  const c = (v) => Math.min(1, Math.max(0, v));
  const x = c(-tx / scale / nw);
  const y = c(-ty / scale / nh);
  return { x, y, w: Math.min(1 - x, fw / scale / nw), h: Math.min(1 - y, fh / scale / nh) };
}

// 動く PNG(APNG)・動く WebP か。切ると最初の一コマになってしまうので、手を付けない。
// head は、ファイルの頭(数十 KB)。
export function isAnimated(type, head) {
  const tag = (o, s) => head.length >= o + s.length && s.split("").every((ch, i) => head[o + i] === ch.charCodeAt(0));
  if (type === "image/webp") return tag(12, "VP8X") && (head[20] & 0x02) !== 0;
  if (type === "image/png") {
    for (let p = 8; p + 8 <= head.length; ) {
      const len = ((head[p] << 24) | (head[p + 1] << 16) | (head[p + 2] << 8) | head[p + 3]) >>> 0;
      if (tag(p + 4, "acTL")) return true;
      if (tag(p + 4, "IDAT")) return false;
      p += 12 + len;
    }
  }
  return false;
}

// 貼り付けた画像の名前。クリップボードの File は、どれも "image.png" なので。
export function pastedName(at, type, i = 0) {
  const p = (n) => String(n).padStart(2, "0");
  const stamp = `${at.getFullYear()}${p(at.getMonth() + 1)}${p(at.getDate())}-${p(at.getHours())}${p(at.getMinutes())}${p(at.getSeconds())}`;
  const ext = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif" }[type] ?? "png";
  return `paste-${stamp}${i ? `-${i + 1}` : ""}.${ext}`;
}

// 貼り付けに文字がまじっているとき、それは「ファイルの名前」だけか。
// (Finder でコピーしたファイルは、名前の文字も一緒に来る。Excel のセルは、本物の文字が来る。)
export function textIsOnlyNames(text, names) {
  const s = text.trim();
  if (!s) return true;
  return names.some((n) => n && s.endsWith(n));
}

export function fmtBytes(n) {
  return n >= 1024 * 1024 ? `${(n / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`;
}

// ── ここから下は、ブラウザの中だけ ─────────────────────────────────────

const isStill = (f) => /^image\/(jpeg|png|webp)$/.test(f.type);

// 画を開く。向きは、ブラウザに直してもらう(from-image)。古い Safari は <img> 経由で。
async function decode(file) {
  try {
    return await createImageBitmap(file, { imageOrientation: "from-image" });
  } catch {
    const url = URL.createObjectURL(file);
    try {
      const img = new Image();
      img.src = url;
      await img.decode();
      return img;
    } finally {
      URL.revokeObjectURL(url);
    }
  }
}
const dims = (src) => ({ w: src.naturalWidth ?? src.width, h: src.naturalHeight ?? src.height });

// 回して、切って、縮めて、canvas に。crop は回したあとの画に対する割合。
// out を渡すと、その大きさに揃える(アバターとヘッダー)。
function paint(src, { rot = 0, crop = null, maxEdge = MAX_EDGE, out = null }) {
  const { w: w0, h: h0 } = dims(src);
  const odd = rot % 2 !== 0;
  const rw = odd ? h0 : w0;
  const rh = odd ? w0 : h0;
  const c = crop ? { x: crop.x * rw, y: crop.y * rh, w: crop.w * rw, h: crop.h * rh } : { x: 0, y: 0, w: rw, h: rh };
  const size = out ?? fitSize(c.w, c.h, maxEdge);
  const k = size.w / c.w;
  const canvas = document.createElement("canvas");
  canvas.width = size.w;
  canvas.height = size.h;
  const ctx = canvas.getContext("2d");
  ctx.imageSmoothingQuality = "high";
  const [a, b, cc, d, e, f] = rotationMatrix(rot, w0, h0);
  ctx.setTransform(k * a, k * b, k * cc, k * d, k * e - c.x * k, k * f - c.y * k);
  ctx.drawImage(src, 0, 0);
  return canvas;
}

const toBlob = (canvas, type, q) => new Promise((ok) => canvas.toBlob(ok, type, q));
// 切り抜きの窓の背景に敷く画。JPEG の元なら透明は無いので JPEG(軽い)。それ以外は、透明を守って PNG。
const backdrop = (canvas, file) => (file.type === "image/jpeg" ? toBlob(canvas, "image/jpeg", 0.9) : toBlob(canvas, "image/png"));

// 下の方が透けているか(小さく縮めて、見るだけ)。PNG の透明を、黒く潰さないため。
function hasAlpha(canvas) {
  const s = document.createElement("canvas");
  s.width = s.height = 32;
  const ctx = s.getContext("2d");
  ctx.drawImage(canvas, 0, 0, 32, 32);
  const px = ctx.getImageData(0, 0, 32, 32).data;
  for (let i = 3; i < px.length; i += 4) if (px[i] < 250) return true;
  return false;
}

// canvas を、いちばんよい形の Blob に。PNG はそのまま PNG(文字や透明を傷めない)。
// 大きすぎる PNG だけ WebP を、それも出せなければ(透けていなければ)JPEG を試す。
async function encode(canvas, type) {
  if (type === "image/jpeg") return toBlob(canvas, "image/jpeg", 0.85);
  if (type === "image/webp") return toBlob(canvas, "image/webp", 0.85);
  const png = await toBlob(canvas, "image/png");
  if (!png || png.size <= BIG_PNG_BYTES) return png;
  const webp = await toBlob(canvas, "image/webp", 0.85);
  if (webp && webp.type === "image/webp" && webp.size < png.size) return webp;
  if (!hasAlpha(canvas)) {
    const flat = document.createElement("canvas");
    flat.width = canvas.width;
    flat.height = canvas.height;
    const ctx = flat.getContext("2d");
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, flat.width, flat.height);
    ctx.drawImage(canvas, 0, 0);
    const jpg = await toBlob(flat, "image/jpeg", 0.9);
    if (jpg && jpg.size < png.size) return jpg;
  }
  return png;
}

const EXT = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };
const asFile = (blob, name) => new File([blob], name.replace(/\.[^.]+$/, "") + "." + (EXT[blob.type] ?? "png"), { type: blob.type });

// 元の File から、いまの回しかた・切りかたで、送る File を作る。
// 手を付けなくてよいときは、元の File をそのまま返す(画質を、これ以上落とさない)。
async function prepare(orig, { rot = 0, crop = null }) {
  if (!isStill(orig)) return { file: orig, edited: false };
  const head = new Uint8Array(await orig.slice(0, 65536).arrayBuffer());
  if (isAnimated(orig.type, head)) return { file: orig, edited: false };
  const orientation = orig.type === "image/jpeg" ? jpegOrientation(head) : 1;
  let src;
  try {
    src = await decode(orig);
  } catch {
    return { file: orig, edited: false, failed: true };
  }
  const { w, h } = dims(src);
  const moved = rot % 4 !== 0 || crop !== null;
  if (!moved && !needsWork({ type: orig.type, size: orig.size, orientation, w, h })) return { file: orig, edited: false, still: true };
  const canvas = paint(src, { rot, crop });
  const blob = await encode(canvas, orig.type);
  if (!blob) return { file: orig, edited: false, still: true };
  // 手を入れたのに大きくなった(向きも縮小も要らなかった)なら、元のまま。
  const geometry = moved || orientation > 1 || canvas.width !== w || canvas.height !== h;
  if (!geometry && blob.size >= orig.size) return { file: orig, edited: false, still: true };
  return { file: asFile(blob, orig.name), edited: true, still: true };
}

// ── 切り抜きの窓 ───────────────────────────────────────────────────
// <dialog> をその場で作る。Esc で閉じる(dialog の作法)。<form> は使わない(Unpoly が拾うので)。
// 返すのは、画像全体に対する割合 {x,y,w,h}。やめたら null、「そのまま」なら "keep"。
function askCrop({ src, ratios, ratio, title, s, keep = false }) {
  return new Promise((resolve) => {
    const dlg = document.createElement("dialog");
    dlg.className = "crop-dialog";
    dlg.setAttribute("aria-label", title);
    dlg.innerHTML = `
      <p class="crop-title"></p>
      <div class="crop-ratios" role="group"></div>
      <div class="crop-frame" tabindex="0"><img alt="" draggable="false" /></div>
      <label class="crop-zoom"><span class="visually-hidden"></span><input type="range" min="1" max="4" step="0.01" value="1" /></label>
      <p class="crop-hint muted"></p>
      <div class="crop-actions"><button type="button" class="chip" data-act="cancel"></button><button type="button" class="chip" data-act="keep" hidden></button><button type="button" class="btn primary px-6 py-2" data-act="ok"></button></div>`;
    const q = (sel) => dlg.querySelector(sel);
    q(".crop-title").textContent = title;
    q(".crop-zoom span").textContent = s.zoom;
    q(".crop-hint").textContent = s.hint;
    q('[data-act="cancel"]').textContent = s.cancel;
    q('[data-act="ok"]').textContent = s.confirm;
    if (keep) {
      q('[data-act="keep"]').textContent = s.keep;
      q('[data-act="keep"]').hidden = false;
    }
    const frame = q(".crop-frame");
    const img = q("img");
    const zoomEl = q(".crop-zoom input");
    img.src = src;

    let nw = 0;
    let nh = 0;
    let fw = 0;
    let fh = 0;
    let aspect = ratio ?? 1;
    let base = 1;
    let st = { scale: 1, tx: 0, ty: 0 };
    let zoom = 1;

    const paintImg = () => {
      img.style.transform = `translate(${st.tx}px, ${st.ty}px) scale(${st.scale})`;
    };
    const clamp = () => {
      st.tx = clampOffset(st.tx, fw, nw * st.scale);
      st.ty = clampOffset(st.ty, fh, nh * st.scale);
    };
    // 窓の大きさを決めて、画像を覆う縮尺で、まんなかに置く。
    const layout = () => {
      const maxW = Math.min(360, innerWidth * 0.8);
      const maxH = innerHeight * 0.5;
      fw = Math.min(maxW, maxH * aspect);
      fh = fw / aspect;
      frame.style.width = `${fw}px`;
      frame.style.height = `${fh}px`;
      base = coverScale(nw, nh, fw, fh);
      zoom = 1;
      zoomEl.value = "1";
      st = { scale: base, tx: (fw - nw * base) / 2, ty: (fh - nh * base) / 2 };
      paintImg();
    };

    // 比率の札。「元の比率」は、画像そのままの縦横比。
    const chips = ratios.map((r) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "chip";
      b.textContent = r.label ?? s.original;
      b.addEventListener("click", () => {
        aspect = r.value ?? nw / nh;
        chips.forEach((c) => c.setAttribute("aria-pressed", String(c === b)));
        layout();
      });
      return b;
    });
    if (ratios.length > 1) q(".crop-ratios").append(...chips);
    else q(".crop-ratios").hidden = true;

    img.addEventListener("load", () => {
      nw = img.naturalWidth;
      nh = img.naturalHeight;
      const first = ratios.findIndex((r) => (r.value ?? nw / nh) === ratio);
      const at = first >= 0 ? first : 0;
      aspect = ratios[at].value ?? nw / nh;
      chips.forEach((c, i) => c.setAttribute("aria-pressed", String(i === at)));
      layout();
    });

    // ドラッグ・ホイール・つまみ・矢印キー。
    let drag = null;
    frame.addEventListener("pointerdown", (e) => {
      drag = { x: e.clientX, y: e.clientY, tx: st.tx, ty: st.ty };
      frame.setPointerCapture(e.pointerId);
    });
    frame.addEventListener("pointermove", (e) => {
      if (!drag) return;
      st.tx = drag.tx + e.clientX - drag.x;
      st.ty = drag.ty + e.clientY - drag.y;
      clamp();
      paintImg();
    });
    const endDrag = () => (drag = null);
    frame.addEventListener("pointerup", endDrag);
    frame.addEventListener("pointercancel", endDrag);
    const setZoom = (z) => {
      zoom = Math.min(4, Math.max(1, z));
      zoomEl.value = String(zoom);
      st = zoomKeepingCenter(st, base * zoom, fw, fh);
      clamp();
      paintImg();
    };
    zoomEl.addEventListener("input", () => setZoom(parseFloat(zoomEl.value)));
    frame.addEventListener("wheel", (e) => {
      e.preventDefault();
      setZoom(zoom * (e.deltaY < 0 ? 1.1 : 1 / 1.1));
    }, { passive: false });
    frame.addEventListener("keydown", (e) => {
      const step = 12;
      const move = { ArrowLeft: [step, 0], ArrowRight: [-step, 0], ArrowUp: [0, step], ArrowDown: [0, -step] }[e.key];
      if (move) {
        e.preventDefault();
        st.tx += move[0];
        st.ty += move[1];
        clamp();
        paintImg();
      } else if (e.key === "+" || e.key === "=") setZoom(zoom * 1.1);
      else if (e.key === "-") setZoom(zoom / 1.1);
    });

    let result = null;
    dlg.addEventListener("click", (e) => {
      const act = e.target.closest?.("[data-act]")?.dataset.act;
      if (act === "ok") result = visibleFraction(st, fw, fh, nw, nh);
      else if (act === "keep") result = "keep";
      else if (act !== "cancel") return;
      dlg.close();
    });
    dlg.addEventListener("close", () => {
      dlg.remove();
      resolve(result);
    });
    document.body.append(dlg);
    dlg.showModal();
    frame.focus();
  });
}

// ── 書く欄に混ぜる部品 ─────────────────────────────────────────────
// Alpine の composeAssist に、そのまま混ぜる(app.js)。外す・回す・切り抜く・貼る・落とす・alt。
function mediaMixin(s) {
  let seq = 0;
  const max = Number(s.max); // 何枚まで。サーバーが決めて、渡してくる
  return {
    items: [],
    busy: 0,
    note: "",
    noteTimer: 0,
    say(msg) {
      this.note = msg;
      clearTimeout(this.noteTimer);
      this.noteTimer = setTimeout(() => (this.note = ""), 5000);
    },
    // 送れない(大きすぎる)ものが残っているか、まだ整え中か。
    notReady() {
      return this.busy > 0 || this.items.some((it) => it.over);
    },
    // <input type=file> に、整えた File を戻す。送るのは、これ。
    sync() {
      const dt = new DataTransfer();
      for (const it of this.items) dt.items.add(it.file);
      this.$refs.files.files = dt.files;
    },
    async refresh(it, { say = false } = {}) {
      this.busy++;
      try {
        const r = await prepare(it.orig, { rot: it.rot, crop: it.crop });
        it.file = r.file;
        it.editable = !!r.still;
        if (it.thumb) URL.revokeObjectURL(it.thumb);
        it.thumb = r.file.type.startsWith("image/") ? URL.createObjectURL(r.file) : "";
        it.label = r.edited ? `${fmtBytes(it.orig.size)} → ${fmtBytes(r.file.size)}` : fmtBytes(r.file.size);
        it.over = r.file.size > LIMIT_BYTES;
        if (r.failed && say) this.say(s.prepFailed);
      } finally {
        this.busy--;
        this.sync();
      }
    },
    async add(list, { pasted = false } = {}) {
      const files = [...list].filter((f) => /^(image|video|audio)\//.test(f.type));
      const room = max - this.items.length;
      if (files.length > room) this.say(s.maxFiles);
      for (const f of files.slice(0, Math.max(0, room))) {
        this.items.push({ id: ++seq, orig: f, file: f, rot: 0, crop: null, alt: "", thumb: "", label: "", editable: false, over: false, name: f.name });
        await this.refresh(this.items[this.items.length - 1], { say: true });
      }
      if (pasted && room > 0) this.say(s.pasted.replace("{n}", this.items.length));
    },
    onFiles(e) {
      this.add(e.target.files);
    },
    // Ctrl+V(Cmd+V・右クリックの貼り付けも同じ)。キーではなく、貼り付けの出来事を聞く。
    onPaste(e) {
      const data = e.clipboardData;
      if (!data) return;
      const files = [...data.files].filter((f) => f.type.startsWith("image/"));
      if (!files.length) return; // 文字だけの貼り付けは、いつもどおり
      if (!textIsOnlyNames(data.getData("text/plain"), files.map((f) => f.name))) return; // 本物の文字が一緒なら、文字を通す
      e.preventDefault();
      const now = new Date();
      const named = files.map((f, i) => (/^image\.\w+$/i.test(f.name) ? new File([f], pastedName(now, f.type, i), { type: f.type }) : f));
      this.add(named, { pasted: true });
    },
    onDragOver(e) {
      if ([...(e.dataTransfer?.types ?? [])].includes("Files")) e.preventDefault();
    },
    onDrop(e) {
      if (!e.dataTransfer?.files?.length) return;
      e.preventDefault();
      this.add(e.dataTransfer.files);
    },
    remove(i) {
      const [it] = this.items.splice(i, 1);
      if (it.thumb) URL.revokeObjectURL(it.thumb);
      this.sync();
    },
    async rotate(i, dir) {
      const it = this.items[i];
      it.crop = null; // 回すと、切った範囲の向きも変わる。切りなおす
      it.rot = (it.rot + dir + 4) % 4;
      await this.refresh(it);
    },
    async cropItem(i) {
      const it = this.items[i];
      this.busy++;
      let src;
      let url;
      try {
        // 切る前の、回しただけの画を、窓に見せる(長い辺 1600 まで)。
        src = await decode(it.orig);
        const canvas = paint(src, { rot: it.rot, maxEdge: 1600 });
        url = URL.createObjectURL(await backdrop(canvas, it.orig));
      } catch {
        this.busy--;
        return;
      }
      this.busy--;
      const r = await askCrop({
        src: url,
        ratios: [{ value: null }, { value: 1, label: "1:1" }, { value: 4 / 3, label: "4:3" }, { value: 16 / 9, label: "16:9" }],
        ratio: null,
        title: s.cropTitle,
        s
      });
      URL.revokeObjectURL(url);
      if (!r || r === "keep") return;
      it.crop = r;
      await this.refresh(it);
    }
  };
}

// ── つなぐ ──────────────────────────────────────────────────────────
if (typeof document !== "undefined") {
  window.sukhiMedia = { mediaMixin };

  // 設定の、アイコンとヘッダー。選んだら窓を開いて、切ったものを入れなおす。
  //   data-crop='{"ratio":1,"w":512,"h":512,"type":"image/png","title":"…","s":{…}}'
  up.compiler("input[data-crop]", (input) => {
    const spec = JSON.parse(input.dataset.crop);
    const onChange = async () => {
      const file = input.files?.[0];
      if (!file || (!isStill(file) && file.type !== "image/gif")) return;
      const gif = file.type === "image/gif";
      let src;
      try {
        src = await decode(file);
      } catch {
        return; // 開けない画は、そのまま送る(サーバーが答える)
      }
      const canvas = paint(src, { maxEdge: 1600 });
      const url = URL.createObjectURL(await backdrop(canvas, file));
      const r = await askCrop({
        src: url,
        ratios: [{ value: spec.ratio, label: null }],
        ratio: spec.ratio,
        title: spec.title,
        s: spec.s,
        keep: gif // 動く GIF は、切ると止まる。そのままも選べる
      });
      URL.revokeObjectURL(url);
      if (r === "keep") return;
      if (!r) {
        input.value = ""; // やめた: 何も選ばなかったことに
        return;
      }
      const blob = await toBlob(paint(src, { crop: r, out: { w: spec.w, h: spec.h } }), spec.type, 0.9);
      const dt = new DataTransfer();
      dt.items.add(asFile(blob, file.name));
      input.files = dt.files;
      const preview = input.parentElement?.querySelector("[data-crop-preview]");
      if (preview) {
        if (preview.dataset.url) URL.revokeObjectURL(preview.dataset.url);
        preview.dataset.url = URL.createObjectURL(blob);
        preview.src = preview.dataset.url;
        preview.hidden = false;
      }
    };
    input.addEventListener("change", onChange);
    return () => input.removeEventListener("change", onChange);
  });
}
