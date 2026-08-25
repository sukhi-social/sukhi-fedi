// ひなたの姿を見せるか隠すか。Hinata.svelte(絵そのもの)と、/hello の
// スイッチ(切り替える手)が、同じ状態を見る ── 選んだ状態は次からも
// 覚えている(localStorage)。
const HIDDEN_KEY = 'nd.hinataHidden';

function loadRevealed(): boolean {
  if (typeof localStorage === 'undefined') return true;
  try {
    return localStorage.getItem(HIDDEN_KEY) !== '1';
  } catch {
    return true;
  }
}

let revealed = $state(loadRevealed());

export function isRevealed(): boolean {
  return revealed;
}

export function toggleRevealed(): void {
  revealed = !revealed;
  if (typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(HIDDEN_KEY, revealed ? '0' : '1');
  } catch {
    /* 保存できなくても、この場では切り替わる */
  }
}
