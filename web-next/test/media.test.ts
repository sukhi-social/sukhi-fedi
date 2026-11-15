// SPDX-License-Identifier: AGPL-3.0-or-later
// 画像を整える部品の、純粋なところ。向き・縮小・切り抜きの窓の数学・貼り付けの見分け。
// (canvas や Alpine に触れるところは、ブラウザで歩く。)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  fitSize,
  jpegOrientation,
  needsWork,
  rotationMatrix,
  coverScale,
  clampOffset,
  zoomKeepingCenter,
  visibleFraction,
  pastedName,
  textIsOnlyNames,
  isAnimated,
  fmtBytes,
  KEEP_BYTES,
  MAX_EDGE
} from '../public/js/media.js';

// ── 大きさ ──────────────────────────────────────────────────────
test('fitSize: 長い辺が収まるまで縮める。拡大はしない', () => {
  assert.deepEqual(fitSize(6000, 4000, 2560), { w: 2560, h: 1707 });
  assert.deepEqual(fitSize(4000, 6000, 2560), { w: 1707, h: 2560 });
  assert.deepEqual(fitSize(800, 600, 2560), { w: 800, h: 600 });
  assert.deepEqual(fitSize(10000, 1, 100), { w: 100, h: 1 }); // 細長くても 0 にならない
});

// ── EXIF の向き ──────────────────────────────────────────────────
// 最小の JPEG の頭: SOI + APP1(Exif, TIFF, IFD0 に向きだけ) + SOS。
function jpegWith(orientation: number, little: boolean, tag = 0x0112): Uint8Array {
  const u16 = (n: number) => (little ? [n & 0xff, n >> 8] : [n >> 8, n & 0xff]);
  const u32 = (n: number) => (little ? [n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, n >>> 24] : [n >>> 24, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);
  const tiff = [...(little ? [0x49, 0x49] : [0x4d, 0x4d]), ...u16(42), ...u32(8), ...u16(1), ...u16(tag), ...u16(3), ...u32(1), ...u16(orientation), 0, 0, ...u32(0)];
  const exif = [0x45, 0x78, 0x69, 0x66, 0, 0, ...tiff];
  const len = exif.length + 2;
  return Uint8Array.from([0xff, 0xd8, 0xff, 0xe1, len >> 8, len & 0xff, ...exif, 0xff, 0xda, 0, 0]);
}

test('jpegOrientation: リトルでもビッグでも、向きを読む', () => {
  for (const o of [1, 3, 6, 8]) {
    assert.equal(jpegOrientation(jpegWith(o, true)), o);
    assert.equal(jpegOrientation(jpegWith(o, false)), o);
  }
});

test('jpegOrientation: 無い・壊れている・範囲の外は 1(そのまま)', () => {
  assert.equal(jpegOrientation(Uint8Array.from([0xff, 0xd8, 0xff, 0xda, 0, 0])), 1);
  assert.equal(jpegOrientation(jpegWith(6, true, 0x0100)), 1); // 向きの札ではない
  assert.equal(jpegOrientation(jpegWith(9, true)), 1);
  assert.equal(jpegOrientation(jpegWith(0, false)), 1);
  assert.equal(jpegOrientation(Uint8Array.from([0x89, 0x50, 0x4e, 0x47])), 1); // JPEG ではない
  assert.equal(jpegOrientation(jpegWith(6, true).subarray(0, 14)), 1); // 途中で切れている
  assert.equal(jpegOrientation(new Uint8Array(0)), 1);
});

// ── 手を付けるか ─────────────────────────────────────────────────
test('needsWork: 向きが違う・大きい・縮めたい、のどれかのときだけ', () => {
  const small = { size: 300_000, w: 1200, h: 800 };
  assert.equal(needsWork({ type: 'image/jpeg', ...small }), false);
  assert.equal(needsWork({ type: 'image/jpeg', ...small, orientation: 6 }), true); // 小さくても、向きは直す
  assert.equal(needsWork({ type: 'image/jpeg', ...small, size: KEEP_BYTES + 1 }), true);
  assert.equal(needsWork({ type: 'image/jpeg', ...small, w: MAX_EDGE + 1 }), true);
  assert.equal(needsWork({ type: 'image/png', ...small }), false);
  assert.equal(needsWork({ type: 'image/png', ...small, orientation: 6 }), false); // PNG に向きは無い
  assert.equal(needsWork({ type: 'image/gif', ...small, size: 99_000_000 }), false); // 動く画は触らない
});

test('isAnimated: 動く WebP と動く PNG を見分ける', () => {
  const webp = (flags: number) => {
    const h = new Uint8Array(30);
    h.set([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x58, 10, 0, 0, 0, flags]);
    return h;
  };
  assert.equal(isAnimated('image/webp', webp(0x02)), true);
  assert.equal(isAnimated('image/webp', webp(0x00)), false);

  const chunk = (name: string, len: number) => [len >>> 24, (len >> 16) & 0xff, (len >> 8) & 0xff, len & 0xff, ...[...name].map((c) => c.charCodeAt(0)), ...new Array(len + 4).fill(0)];
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  assert.equal(isAnimated('image/png', Uint8Array.from([...sig, ...chunk('IHDR', 13), ...chunk('acTL', 8), ...chunk('IDAT', 4)])), true);
  assert.equal(isAnimated('image/png', Uint8Array.from([...sig, ...chunk('IHDR', 13), ...chunk('IDAT', 4)])), false);
  assert.equal(isAnimated('image/jpeg', new Uint8Array(30)), false);
});

// ── 回す ────────────────────────────────────────────────────────
test('rotationMatrix: 時計回りに 90° ずつ。左上の角が、順に右上・右下・左下へ行く', () => {
  const at = (rot: number, x: number, y: number, w0: number, h0: number) => {
    const [a, b, c, d, e, f] = rotationMatrix(rot, w0, h0);
    return [a * x + c * y + e, b * x + d * y + f];
  };
  // 4×2 の画。回すと 2×4(90°・270°)か 4×2(180°)。
  assert.deepEqual(at(0, 0, 0, 4, 2), [0, 0]);
  assert.deepEqual(at(1, 0, 0, 4, 2), [2, 0]); // 右上
  assert.deepEqual(at(2, 0, 0, 4, 2), [4, 2]); // 右下
  assert.deepEqual(at(3, 0, 0, 4, 2), [0, 4]); // 左下
  assert.deepEqual(at(1, 4, 2, 4, 2), [0, 4]); // 右下の角は、左下へ
  assert.deepEqual(at(4, 0, 0, 4, 2), [0, 0]); // 四回で一周
  assert.deepEqual(at(-1, 0, 0, 4, 2), at(3, 0, 0, 4, 2)); // 左へ一回 = 右へ三回
});

// ── 切り抜きの窓 ─────────────────────────────────────────────────
test('coverScale / clampOffset: 窓をいつも覆う', () => {
  assert.equal(coverScale(2000, 1000, 360, 360), 0.36); // 横長を正方形の窓へ: 縦に合わせる
  assert.equal(coverScale(1000, 2000, 360, 360), 0.36);
  assert.equal(clampOffset(50, 360, 720), 0); // 左上の外へは出さない
  assert.equal(clampOffset(-500, 360, 720), -360); // 右下の外へも
  assert.equal(clampOffset(-100, 360, 720), -100);
});

test('zoomKeepingCenter: 窓の中心に見えている点が動かない', () => {
  const before = { scale: 0.36, tx: -180, ty: 0 }; // 2000×1000 を 360 角の窓に置いたところ
  const centre = (st: typeof before) => [(180 - st.tx) / st.scale, (180 - st.ty) / st.scale];
  const after = zoomKeepingCenter(before, 0.72, 360, 360);
  assert.equal(after.scale, 0.72);
  const [bx, by] = centre(before);
  const [ax, ay] = centre(after);
  assert.ok(Math.abs(bx - ax) < 1e-9 && Math.abs(by - ay) < 1e-9);
});

test('visibleFraction: 窓に見えている範囲が、画像全体の割合で返る', () => {
  // 覆っただけ(縮尺 0.36)。2000×1000 のうち、まんなかの 1000×1000 が見える。
  assert.deepEqual(visibleFraction({ scale: 0.36, tx: -180, ty: 0 }, 360, 360, 2000, 1000), { x: 0.25, y: 0, w: 0.5, h: 1 });
  // 二倍に寄る。見える範囲は半分に。
  const z = visibleFraction({ scale: 0.72, tx: -540, ty: -180 }, 360, 360, 2000, 1000);
  assert.ok(Math.abs(z.x - 0.375) < 1e-9 && Math.abs(z.w - 0.25) < 1e-9 && Math.abs(z.y - 0.25) < 1e-9 && Math.abs(z.h - 0.5) < 1e-9);
  // はみ出して見えたら、画像の中に収める。
  const out = visibleFraction({ scale: 0.36, tx: 50, ty: 0 }, 360, 360, 2000, 1000);
  assert.ok(out.x >= 0 && out.x + out.w <= 1);
});

// ── 貼り付け ────────────────────────────────────────────────────
test('pastedName: 時刻で名づける。同時に何枚か来たら番号を足す', () => {
  const at = new Date(2026, 10, 15, 16, 15, 30);
  assert.equal(pastedName(at, 'image/png'), 'paste-20261115-161530.png');
  assert.equal(pastedName(at, 'image/jpeg', 0), 'paste-20261115-161530.jpg');
  assert.equal(pastedName(at, 'image/png', 1), 'paste-20261115-161530-2.png');
  assert.equal(pastedName(at, 'image/bmp'), 'paste-20261115-161530.png');
});

test('textIsOnlyNames: ファイル名だけなら画像を取る。本物の文字が来たら文字を通す', () => {
  assert.equal(textIsOnlyNames('', ['a.png']), true); // スクリーンショット
  assert.equal(textIsOnlyNames('  ', ['a.png']), true);
  assert.equal(textIsOnlyNames('cat.jpg', ['cat.jpg']), true); // Finder のコピー
  assert.equal(textIsOnlyNames('/Users/me/Pictures/cat.jpg', ['cat.jpg']), true);
  assert.equal(textIsOnlyNames('売上\t12\n費用\t7', ['image.png']), false); // Excel のセル
});

test('fmtBytes', () => {
  assert.equal(fmtBytes(500), '1 KB');
  assert.equal(fmtBytes(250_000), '244 KB');
  assert.equal(fmtBytes(5.2 * 1024 * 1024), '5.2 MB');
});
