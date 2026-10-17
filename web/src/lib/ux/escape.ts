// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Esc は「一時的な UI」をひとつ閉じる ── それだけ。
//
// Microsoft の Keyboard interactions は、Esc を「一時的な UI(ダイアログ・
// ドロップダウン)の取消」と定め、「アプリの UI を閉じたり、戻ったりは
// しない」とまで言う。だから、ここに積まれるのは開いている窓とメニュー
// だけで、画面の遷移には触れない。
//
// 窓ごとに自分で keydown を持つと、重なったとき(窓の上のメニュー)に
// 全部が一度に閉じてしまう。Esc は一か所で受け、いちばん上のものだけを
// 閉じる。入力欄が先に Esc を使った(候補を閉じた)ときは、
// defaultPrevented を見て、こちらは何もしない。

const stack: Array<() => void> = [];
let installed = false;

function onKeydown(e: KeyboardEvent) {
  if (e.key !== 'Escape' || e.defaultPrevented || e.isComposing) return;
  const top = stack[stack.length - 1];
  if (!top) return;
  e.preventDefault();
  top();
}

// 返り値は、積んだものを外す関数。
export function onEscape(close: () => void): () => void {
  if (!installed && typeof window !== 'undefined') {
    window.addEventListener('keydown', onKeydown);
    installed = true;
  }
  stack.push(close);
  return () => {
    const i = stack.lastIndexOf(close);
    if (i >= 0) stack.splice(i, 1);
  };
}
